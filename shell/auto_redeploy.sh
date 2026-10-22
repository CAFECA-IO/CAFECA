#!/usr/bin/env bash
# CAFECA 健康檢查與自動修復（在跑 cafeca.io 的伺服器上執行）
#
#   shell/auto_redeploy.sh                 檢查；正常就結束，異常時嘗試修復
#   shell/auto_redeploy.sh --check         只檢查、不修復（結束碼：0 正常、1 異常）
#   shell/auto_redeploy.sh --install-cron  每 5 分鐘自動執行（寫入 crontab）
#   shell/auto_redeploy.sh --uninstall-cron
#
# 檢查項目                                  異常時的修復
#   1. 錢包服務（本機埠）回應、設定檔正確     重新啟動 → 重新建置後啟動 → 重新安裝相依套件、建置後啟動
#   2. 主要頁面可開啟                         同上
#   3. 鏈 RPC 可連（經由 /api/rpc）           無法自動修復（鏈或節點問題），發出警示
#   4. 事件索引沒有停滯                       重新啟動 → 索引資料移到備份資料夾、重新同步
#   5. 對外網址可連                           反向代理（nginx／caddy）未執行時啟動它；其他情況發出警示
#   6. KYC 模型與 ffmpeg                      重新下載模型；ffmpeg 需要人工安裝
#   7. 排程（身分同步、法人監控、每日維護）    重新寫入 crontab
#   8. paymaster 押金、營運錢包 BOLT 餘額      無法自動修復（涉及資金），發出警示
#   9. 磁碟空間                               清除 .next/cache；仍不足時發出警示
#  10. Node.js 版本與 .nvmrc（24.22.1）一致     有 nvm 時自動安裝並切換；否則發出警示
#
# 不會做的事：git pull、部署或變更合約、移動資金、修改 .env.local 的金鑰。要更新程式請用 npm run deploy:server。
#
# 選項（環境變數，也可以寫在 app/.env.local）
#   PORT=10002                 錢包服務的本機埠（與 package.json 的 npm start 一致）
#   PM2_NAME=cafeca            以 pm2 管理時的程序名稱
#   SYSTEMD_UNIT=xxx           以 systemd 管理時的服務名稱
#   PUBLIC_ORIGIN              對外網址（預設讀 app/.env.local）
#   ALERT_WEBHOOK              修復或需要人工處理時通知（POST {"text": …}，Slack／Google Chat／Discord 相容）
#   MAX_REPAIRS_PER_HOUR=3     一小時內最多自動修復幾次，超過就只發警示（避免反覆重啟）
#   INDEX_MAX_LAG=200          索引落後鏈高超過這麼多區塊且 5 分鐘沒有進度，視為停滯
#   MIN_PAYMASTER_DEPOSIT=1    paymaster 押金低於此值（BOLT）發出警示
#   MIN_OPERATOR_BALANCE=1     營運錢包餘額低於此值（BOLT）發出警示
#   DISK_MAX_PCT=90            磁碟使用率超過此值時清理
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_DIR="$ROOT/app"
ENV_FILE="$APP_DIR/.env.local"
STATE_DIR="$APP_DIR/data/auto-redeploy"
LOG_FILE="$STATE_DIR/auto-redeploy.log"
APP_LOG="$STATE_DIR/app.log"
mkdir -p "$STATE_DIR"

env_get() { [ -f "$ENV_FILE" ] && grep -E "^$1=" "$ENV_FILE" | tail -1 | cut -d= -f2- || true; }
cfg() { local v="${!1:-}"; [ -n "$v" ] && { echo "$v"; return; }; v="$(env_get "$1")"; echo "${v:-$2}"; }

PORT="$(cfg PORT 10002)"
PM2_NAME="$(cfg PM2_NAME cafeca)"
SYSTEMD_UNIT="$(cfg SYSTEMD_UNIT "")"
ORIGIN="$(cfg PUBLIC_ORIGIN "")"; ORIGIN="${ORIGIN%/}"
ALERT_WEBHOOK="$(cfg ALERT_WEBHOOK "")"
MAX_REPAIRS_PER_HOUR="$(cfg MAX_REPAIRS_PER_HOUR 3)"
INDEX_MAX_LAG="$(cfg INDEX_MAX_LAG 200)"
MIN_PAYMASTER_DEPOSIT="$(cfg MIN_PAYMASTER_DEPOSIT 1)"
MIN_OPERATOR_BALANCE="$(cfg MIN_OPERATOR_BALANCE 1)"
DISK_MAX_PCT="$(cfg DISK_MAX_PCT 90)"
LOCAL="http://127.0.0.1:$PORT"

MODE="repair"
case "${1:-}" in
  --check) MODE="check" ;;
  --install-cron | --uninstall-cron) MODE="${1#--}" ;;
  "") ;;
  -h | --help) sed -n '2,33p' "$0"; exit 0 ;;
  *) echo "未知參數：$1（--check、--install-cron、--uninstall-cron）" >&2; exit 2 ;;
esac

ts() { date '+%Y-%m-%d %H:%M:%S'; }
log() { printf '%s %s\n' "$(ts)" "$*" | tee -a "$LOG_FILE"; }
ok() { log "  ✓ $*"; }
bad() { log "  ✕ $*"; }
note() { log "  ! $*"; }

alert() {
  local msg="[CAFECA ${ORIGIN:-$(hostname)}] $*"
  log "通知：$*"
  [ -n "$ALERT_WEBHOOK" ] || return 0
  local body
  body="$(node -e 'process.stdout.write(JSON.stringify({text:process.argv[1],content:process.argv[1]}))' "$msg")"
  curl -fsS -m 10 -X POST -H 'content-type: application/json' -d "$body" "$ALERT_WEBHOOK" >/dev/null 2>&1 || log "  ! 通知送出失敗"
}

# 同一則警示在一段時間內只送一次（餘額偏低 6 小時、持續異常 1 小時），每 5 分鐘檢查也不會洗版
alert_once() {
  local key="$1" ttl="$2"; shift 2
  local f="$STATE_DIR/alert-$key" now; now="$(date +%s)"
  if [ -f "$f" ] && [ $((now - $(cat "$f"))) -lt "$ttl" ]; then log "（已通知過，暫不重複）$*"; return 0; fi
  echo "$now" >"$f"
  alert "$@"
}

# ───────────────────────── 排程 ─────────────────────────
if [ "$MODE" = "install-cron" ] || [ "$MODE" = "uninstall-cron" ]; then
  command -v crontab >/dev/null || { echo "這台主機沒有 crontab" >&2; exit 1; }
  line="*/5 * * * * cd $ROOT && bash shell/auto_redeploy.sh >/dev/null 2>&1 # cafeca-auto-redeploy"
  if [ "$MODE" = "install-cron" ]; then
    ( crontab -l 2>/dev/null | grep -v "# cafeca-auto-redeploy"; echo "$line" ) | crontab -
    echo "已加入 crontab：每 5 分鐘執行一次；紀錄在 $LOG_FILE"
  else
    crontab -l 2>/dev/null | grep -v "# cafeca-auto-redeploy" | crontab -
    echo "已移除 crontab 中的 auto_redeploy"
  fi
  exit 0
fi

# 同一時間只跑一個（cron 每 5 分鐘觸發，重新建置可能超過 5 分鐘）
exec 9>"$STATE_DIR/lock"
if command -v flock >/dev/null && ! flock -n 9; then
  echo "$(ts) 另一個 auto_redeploy 正在執行，略過" | tee -a "$LOG_FILE"
  exit 0
fi

cd "$APP_DIR" || { echo "找不到 $APP_DIR" >&2; exit 1; }

# Node.js 版本：cron 的 PATH 很精簡，有 nvm 就載入並切換到 .nvmrc 指定的版本（修復模式下缺少時自動安裝）
WANT_NODE="$(tr -d ' \n' < "$ROOT/.nvmrc" 2>/dev/null || true)"
if [ -s "${NVM_DIR:-$HOME/.nvm}/nvm.sh" ]; then
  # shellcheck disable=SC1091
  . "${NVM_DIR:-$HOME/.nvm}/nvm.sh" >/dev/null 2>&1
  if [ -n "$WANT_NODE" ] && ! nvm use "$WANT_NODE" >/dev/null 2>&1 && [ "$MODE" = "repair" ]; then
    log "→ 安裝 Node.js $WANT_NODE（nvm）"
    nvm install "$WANT_NODE" >/dev/null 2>&1 && nvm use "$WANT_NODE" >/dev/null 2>&1
  fi
fi
command -v node >/dev/null || { alert "找不到 node（cron 的 PATH 沒有 Node.js；請安裝 nvm 或把 node 加進 PATH）"; exit 1; }
[ -f "$ENV_FILE" ] || { alert "找不到 app/.env.local，無法檢查（第一次部署請執行 npm run deploy:server）"; exit 1; }

# ───────────────────────── 檢查 ─────────────────────────
http_code() { curl -s -o /dev/null -m "${2:-10}" -w '%{http_code}' "$1" 2>/dev/null || echo 000; }
json_get() { curl -fsS -m "${2:-10}" "$1" 2>/dev/null || true; }
rpc() { curl -fsS -m 10 -H 'content-type: application/json' -d "$1" "$LOCAL/api/rpc" 2>/dev/null || true; }

DEP_FILE="deployments/boltchain-testnet.local.json"
[ -f "$DEP_FILE" ] || DEP_FILE="deployments/boltchain-testnet.json"

APP_OK=1 PAGES_OK=1 RPC_OK=1 INDEX_OK=1 PUBLIC_OK=1 MODELS_OK=1 FFMPEG_OK=1 CRON_OK=1 DISK_OK=1
FUNDS_MSG="" NODE_MSG=""

check_app() {
  local cfgj
  cfgj="$(json_get "$LOCAL/.well-known/cafeca-configuration")"
  if [ -z "$cfgj" ]; then APP_OK=0; bad "錢包服務 $LOCAL 沒有回應"; return; fi
  if echo "$cfgj" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{const c=JSON.parse(s);process.exit(c.issuer&&c.contracts&&c.contracts.keyring?0:1)})' 2>/dev/null; then
    APP_OK=1; ok "錢包服務正常（$LOCAL）"
  else
    APP_OK=0; bad "設定檔內容不完整（合約位址缺少：可能建置時沒有讀到部署檔）"
  fi
}

check_pages() {
  local p c failed=""
  for p in /start /wallet /admin; do
    c="$(http_code "$LOCAL$p" 20)"
    [ "$c" = "200" ] || failed="$failed $p($c)"
  done
  if [ -z "$failed" ]; then PAGES_OK=1; ok "主要頁面可開啟"; else PAGES_OK=0; bad "頁面異常：$failed"; fi
}

check_rpc() {
  local r
  r="$(rpc '{"jsonrpc":"2.0","id":1,"method":"eth_blockNumber","params":[]}')"
  if echo "$r" | grep -q '"result":"0x'; then RPC_OK=1; ok "鏈 RPC 正常（區塊 $(node -p "parseInt(JSON.parse(process.argv[1]).result,16)" "$r")）"
  else RPC_OK=0; bad "鏈 RPC 無法連線：${r:-沒有回應}"; fi
}

check_index() {
  local j verdict
  j="$(json_get "$LOCAL/api/index/status" 20)"
  [ -n "$j" ] || { INDEX_OK=0; bad "事件索引狀態沒有回應"; return; }
  # 進度記錄：落後過多且 5 分鐘內 lastBlock 沒有前進 → 停滯
  verdict="$(node -e '
    const fs=require("fs"); const [j,max,file]=process.argv.slice(1); const s=JSON.parse(j);
    let prev={}; try{prev=JSON.parse(fs.readFileSync(file,"utf8"))}catch{}
    const now=Date.now(), lag=s.head==null?null:s.head-s.lastBlock;
    let since=prev.lastBlock===s.lastBlock?(prev.since??now):now;
    fs.writeFileSync(file,JSON.stringify({lastBlock:s.lastBlock,since}));
    const stalled=lag!==null&&lag>Number(max)&&now-since>5*60_000;
    console.log((stalled?"STALL ":"OK ")+`同步到 #${s.lastBlock}／鏈高 #${s.head}（落後 ${lag}）`+(s.lastError?`；錯誤：${s.lastError}`:""));
  ' "$j" "$INDEX_MAX_LAG" "$STATE_DIR/index-progress.json" 2>/dev/null || echo "STALL 無法解析索引狀態")"
  if [ "${verdict%% *}" = "OK" ]; then INDEX_OK=1; ok "事件索引${verdict#OK }"; else INDEX_OK=0; bad "事件索引停滯：${verdict#STALL }"; fi
}

check_public() {
  [ -n "$ORIGIN" ] || { note "沒有設定 PUBLIC_ORIGIN，略過對外檢查"; return; }
  case "$ORIGIN" in http://localhost* | http://127.0.0.1*) return ;; esac
  local c; c="$(http_code "$ORIGIN/.well-known/cafeca-configuration" 15)"
  if [ "$c" = "200" ]; then PUBLIC_OK=1; ok "對外網址正常（$ORIGIN）"; else PUBLIC_OK=0; bad "對外網址異常：$ORIGIN 回應 $c"; fi
}

check_kyc() {
  local f missing=""
  for f in face_detection_yunet_2023mar.onnx face_recognition_sface_2021dec.onnx face_landmarks_478.onnx ppocrv5_det.onnx ppocrv5_rec.onnx ppocrv5_dict.txt whisper/onnx-community/whisper-base/onnx/encoder_model_quantized.onnx; do
    [ -s "${KYC_MODEL_DIR:-models/kyc}/$f" ] || missing="$missing $f"
  done
  if [ -z "$missing" ]; then MODELS_OK=1; ok "KYC 模型齊全"; else MODELS_OK=0; bad "缺少 KYC 模型：$missing（案件會全部轉人工）"; fi
  if command -v "${FFMPEG_PATH:-ffmpeg}" >/dev/null; then FFMPEG_OK=1; else FFMPEG_OK=0; bad "沒有 ffmpeg：KYC 無法解碼臉部影片"; fi
}

check_cron() {
  command -v crontab >/dev/null || { note "沒有 crontab，略過排程檢查"; return; }
  local cur missing=""; cur="$(crontab -l 2>/dev/null || true)"
  for tag in cafeca-identity-sync cafeca-entity-sync cafeca-maintenance; do
    echo "$cur" | grep -q "# $tag" || missing="$missing $tag"
  done
  if [ -z "$missing" ]; then CRON_OK=1; ok "排程齊全"; else CRON_OK=0; bad "缺少排程：$missing"; fi
}

check_funds() {
  [ "$APP_OK" = 1 ] && [ "$RPC_OK" = 1 ] || return
  FUNDS_MSG="$(node -e '
    const [dep, key, rpc, minPm, minOp] = process.argv.slice(1);
    const d = require("./" + dep);
    const { privateKeyToAccount } = require("viem/accounts");
    const call = (method, params) => fetch(rpc, { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ jsonrpc: "2.0", id: 1, method, params }) }).then((r) => r.json()).then((j) => BigInt(j.result));
    const fmt = (v) => (Number(v) / 1e18).toFixed(3);
    (async () => {
      const out = [];
      if (d.entryPoint && d.paymaster) {
        // EntryPoint.balanceOf(paymaster)
        const dep = await call("eth_call", [{ to: d.entryPoint, data: "0x70a08231" + d.paymaster.slice(2).toLowerCase().padStart(64, "0") }, "latest"]);
        out.push((dep < BigInt(Math.round(Number(minPm) * 1e18)) ? "LOW " : "OK ") + `paymaster 押金 ${fmt(dep)} BOLT`);
      }
      if (key) {
        const bal = await call("eth_getBalance", [privateKeyToAccount(key).address, "latest"]);
        out.push((bal < BigInt(Math.round(Number(minOp) * 1e18)) ? "LOW " : "OK ") + `營運錢包 ${fmt(bal)} BOLT`);
      }
      console.log(out.join("\n"));
    })().catch((e) => console.log("ERR " + e.message));
  ' "$DEP_FILE" "$(env_get DEPLOYER_PRIVATE_KEY)" "$LOCAL/api/rpc" "$MIN_PAYMASTER_DEPOSIT" "$MIN_OPERATOR_BALANCE" 2>/dev/null)"
  local l
  while IFS= read -r l; do
    [ -n "$l" ] || continue
    case "$l" in OK*) ok "${l#OK }" ;; LOW*) bad "${l#LOW }（偏低：使用者交易會無法贊助 gas，請補充）" ;; *) note "無法查詢餘額：${l#ERR }" ;; esac
  done <<<"$FUNDS_MSG"
}

check_disk() {
  local pct; pct="$(df -P "$APP_DIR" | awk 'NR==2{gsub("%","",$5);print $5}')"
  if [ "${pct:-0}" -lt "$DISK_MAX_PCT" ]; then DISK_OK=1; ok "磁碟使用率 ${pct}%"; else DISK_OK=0; bad "磁碟使用率 ${pct}%（上限 ${DISK_MAX_PCT}%）"; fi
}

check_node() {
  [ -n "$WANT_NODE" ] || return
  if [ "$(node -v)" = "v$WANT_NODE" ]; then ok "Node.js $(node -v)"
  else bad "Node.js 版本 $(node -v)，應為 v$WANT_NODE（.nvmrc）：請執行 nvm install $WANT_NODE 後重新部署"; NODE_MSG="$(node -v)"; fi
}

run_checks() {
  NODE_MSG=""
  APP_OK=1 PAGES_OK=1 RPC_OK=1 INDEX_OK=1 PUBLIC_OK=1 MODELS_OK=1 FFMPEG_OK=1 CRON_OK=1 DISK_OK=1
  check_app
  if [ "$APP_OK" = 1 ]; then check_pages; check_rpc; [ "$RPC_OK" = 1 ] && check_index; check_public; fi
  check_kyc; check_cron; check_funds; check_disk; check_node
}

healthy() { [ "$APP_OK$PAGES_OK$RPC_OK$INDEX_OK$PUBLIC_OK$MODELS_OK$FFMPEG_OK$CRON_OK$DISK_OK" = "111111111" ]; }
funds_low() { grep -q '^LOW' <<<"$FUNDS_MSG"; }

# ───────────────────────── 修復動作 ─────────────────────────
app_logs() {
  if [ -n "$SYSTEMD_UNIT" ]; then journalctl -u "$SYSTEMD_UNIT" -n 30 --no-pager 2>/dev/null
  elif command -v pm2 >/dev/null && pm2 describe "$PM2_NAME" >/dev/null 2>&1; then pm2 logs "$PM2_NAME" --nostream --lines 30 2>/dev/null
  else tail -n 30 "$APP_LOG" 2>/dev/null; fi | tail -n 30
}

restart_app() {
  log "→ 重新啟動錢包服務"
  # 啟動的服務不能繼承鎖檔的 fd 9，否則之後的檢查都會以為「另一個 auto_redeploy 正在執行」
  if [ -n "$SYSTEMD_UNIT" ]; then
    if [ "$(id -u)" -eq 0 ]; then systemctl restart "$SYSTEMD_UNIT" 9>&-; else sudo -n systemctl restart "$SYSTEMD_UNIT" 9>&-; fi
  elif command -v pm2 >/dev/null; then
    if pm2 describe "$PM2_NAME" >/dev/null 2>&1; then pm2 restart "$PM2_NAME" --update-env >/dev/null 9>&-
    else pm2 start npm --name "$PM2_NAME" -- start >/dev/null 9>&-; fi
    pm2 save >/dev/null 2>&1 || true
  else
    # 沒有程序管理工具：結束佔用埠的程序後以 nohup 啟動（建議改用 pm2 或 systemd）
    local pids; pids="$( (command -v lsof >/dev/null && lsof -ti "tcp:$PORT" -sTCP:LISTEN) || (ss -ltnpH "sport = :$PORT" 2>/dev/null | grep -o 'pid=[0-9]*' | cut -d= -f2) || true)"
    for p in $pids; do kill "$p" 2>/dev/null; done
    sleep 2
    nohup npx next start -p "$PORT" >>"$APP_LOG" 2>&1 9>&- &
  fi
}

wait_app() {
  local _
  for _ in $(seq 1 45); do
    [ "$(http_code "$LOCAL/.well-known/cafeca-configuration" 5)" = "200" ] && return 0
    sleep 2
  done
  return 1
}

rebuild() {
  log "→ 重新建置（npm run build）"
  rm -rf .next/cache
  npm run build >>"$STATE_DIR/build.log" 2>&1 || { bad "建置失敗，紀錄在 $STATE_DIR/build.log"; tail -n 20 "$STATE_DIR/build.log" | sed 's/^/      /' | tee -a "$LOG_FILE"; return 1; }
}

reinstall() {
  log "→ 重新安裝相依套件（npm ci）"
  if [ -f package-lock.json ]; then npm ci >>"$STATE_DIR/build.log" 2>&1; else npm install >>"$STATE_DIR/build.log" 2>&1; fi || { bad "安裝相依套件失敗，紀錄在 $STATE_DIR/build.log"; return 1; }
}

build_stale() {
  [ -f .next/BUILD_ID ] || return 0
  git -C "$ROOT" rev-parse >/dev/null 2>&1 || return 1
  local code built
  code="$(git -C "$ROOT" log -1 --format=%ct -- app 2>/dev/null || echo 0)"
  built="$(stat -c %Y .next/BUILD_ID 2>/dev/null || stat -f %m .next/BUILD_ID)"
  [ "${code:-0}" -gt "${built:-0}" ]
}

ensure_cron() {
  local secret; secret="$(env_get CRON_SECRET)"
  local origin="${ORIGIN:-$LOCAL}"
  log "→ 重新寫入排程"
  (
    crontab -l 2>/dev/null | grep -v "# cafeca-identity-sync" | grep -v "# cafeca-entity-sync" | grep -v "# cafeca-maintenance"
    echo "*/5 * * * * curl -fsS -X POST $origin/api/identity/sync > /dev/null 2>&1 # cafeca-identity-sync"
    echo "17 3 * * * curl -fsS -X POST $origin/api/entity/sync > /dev/null 2>&1 # cafeca-entity-sync"
    echo "41 3 * * * curl -fsS -X POST -H 'x-cafeca-cron: $secret' $origin/api/maintenance > /dev/null 2>&1 # cafeca-maintenance"
  ) | crontab -
}

restart_proxy() {
  command -v systemctl >/dev/null || return 1
  local s
  for s in nginx caddy apache2 httpd; do
    if systemctl list-unit-files "$s.service" >/dev/null 2>&1 && systemctl list-unit-files "$s.service" | grep -q "^$s.service" && ! systemctl is-active --quiet "$s"; then
      log "→ 反向代理 $s 沒有執行，啟動它"
      if [ "$(id -u)" -eq 0 ]; then systemctl start "$s" 9>&-; else sudo -n systemctl start "$s" 9>&-; fi
      return $?
    fi
  done
  return 1
}

# 一小時內的自動修復次數（避免反覆重啟把問題放大）
repairs_recent() { node -e 'const fs=require("fs");let a=[];try{a=JSON.parse(fs.readFileSync(process.argv[1],"utf8"))}catch{}console.log(a.filter(t=>Date.now()-t<3600_000).length)' "$STATE_DIR/repairs.json"; }
record_repair() { node -e 'const fs=require("fs"),f=process.argv[1];let a=[];try{a=JSON.parse(fs.readFileSync(f,"utf8"))}catch{}a=a.filter(t=>Date.now()-t<86400_000);a.push(Date.now());fs.writeFileSync(f,JSON.stringify(a))' "$STATE_DIR/repairs.json"; }

# ───────────────────────── 主流程 ─────────────────────────
log "── 檢查開始（$MODE）"
run_checks
# 版本不符不算服務異常（服務仍可運作），只提醒；重新建置會用到目前的 node，所以提醒要先處理
[ -n "$NODE_MSG" ] && alert_once node 21600 "Node.js 版本是 $NODE_MSG，應為 v$WANT_NODE（.nvmrc）。請在伺服器執行 nvm install $WANT_NODE && nvm alias default $WANT_NODE，再 npm run deploy:server"
if funds_low; then alert_once funds 21600 "餘額偏低：$(grep '^LOW' <<<"$FUNDS_MSG" | sed 's/^LOW //' | paste -sd '；' -)。請補充（自動修復不會移動資金）"; fi

if healthy; then
  rm -f "$STATE_DIR"/alert-fail-* "$STATE_DIR/alert-giveup"
  build_stale && note "程式碼比目前的建置新：服務正常所以不處理；要套用新程式請執行 npm run deploy:server"
  log "── 系統正常，不處理"
  exit 0
fi

if [ "$MODE" = "check" ]; then
  log "── 有異常（--check 模式，不修復）"
  exit 1
fi

n="$(repairs_recent)"
if [ "$n" -ge "$MAX_REPAIRS_PER_HOUR" ]; then
  alert_once giveup 3600 "一小時內已自動修復 $n 次仍有異常，停止自動修復，請人工處理。最近的服務紀錄：
$(app_logs)"
  exit 1
fi
record_repair
actions=()

# 1. 排程、模型、磁碟（不影響服務，可直接處理）
if [ "$CRON_OK" = 0 ]; then ensure_cron && actions+=("重新寫入排程"); fi
if [ "$MODELS_OK" = 0 ]; then log "→ 重新下載 KYC 模型"; npm run fetch-models >>"$STATE_DIR/build.log" 2>&1 && actions+=("重新下載 KYC 模型"); fi
if [ "$DISK_OK" = 0 ]; then log "→ 清除 .next/cache"; rm -rf .next/cache && actions+=("清除建置快取"); fi

# 2. 錢包服務：重新啟動 → 重新建置 → 重新安裝相依套件
if [ "$APP_OK" = 0 ] || [ "$PAGES_OK" = 0 ] || [ "$INDEX_OK" = 0 ]; then
  fixed=0
  if build_stale; then
    log "建置不存在或比程式碼舊，直接重新建置"
  else
    restart_app; actions+=("重新啟動服務")
    if wait_app; then run_checks; [ "$APP_OK$PAGES_OK" = "11" ] && fixed=1; fi
  fi
  if [ "$fixed" = 0 ] && [ "$APP_OK$PAGES_OK" != "11" ]; then
    if rebuild; then
      actions+=("重新建置"); restart_app
      if wait_app; then run_checks; [ "$APP_OK$PAGES_OK" = "11" ] && fixed=1; fi
    fi
  fi
  if [ "$fixed" = 0 ] && [ "$APP_OK$PAGES_OK" != "11" ]; then
    if reinstall && rebuild; then
      actions+=("重新安裝相依套件並建置"); restart_app
      wait_app && run_checks
    fi
  fi
  # 索引停滯：重新啟動後仍停滯 → 索引資料移到備份資料夾，重新同步（索引可隨時重建）
  if [ "$APP_OK" = 1 ] && [ "$RPC_OK" = 1 ] && [ "$INDEX_OK" = 0 ]; then
    if [ "${fixed}" = 0 ] && ! printf '%s\n' ${actions[@]+"${actions[@]}"} | grep -q "重新啟動服務"; then restart_app; wait_app; fi
    sleep 20; check_index
    if [ "$INDEX_OK" = 0 ] && [ -d data/index ]; then
      bk="data/index.broken-$(date +%Y%m%d%H%M%S)"
      log "→ 索引仍停滯，移到 $bk 並重新同步"
      mv data/index "$bk" && restart_app && wait_app && actions+=("重建事件索引（舊資料在 app/$bk）")
      rm -f "$STATE_DIR/index-progress.json"
    fi
  fi
fi

# 3. 對外網址：本機正常但外部連不到 → 反向代理沒有執行時啟動它
if [ "$APP_OK" = 1 ] && [ "$PUBLIC_OK" = 0 ]; then
  restart_proxy && actions+=("啟動反向代理") && sleep 3
fi

# ───────────────────────── 修復後再檢查 ─────────────────────────
log "── 修復後重新檢查"
run_checks
join() { local out="" x; for x in "$@"; do out="${out:+$out、}$x"; done; echo "$out"; }
done_msg="$(join ${actions[@]+"${actions[@]}"})"; done_msg="${done_msg:-（沒有可自動執行的修復）}"
if healthy; then
  rm -f "$STATE_DIR"/alert-fail-* "$STATE_DIR/alert-giveup"
  alert "偵測到異常，已自動修復：$done_msg"
  exit 0
fi

problems=()
[ "$APP_OK" = 0 ] && problems+=("錢包服務沒有回應")
[ "$PAGES_OK" = 0 ] && problems+=("頁面異常")
[ "$RPC_OK" = 0 ] && problems+=("鏈 RPC 無法連線（節點或網路問題，需人工處理）")
[ "$INDEX_OK" = 0 ] && problems+=("事件索引停滯")
[ "$PUBLIC_OK" = 0 ] && problems+=("對外網址無法連線（檢查 DNS、TLS 憑證、反向代理設定）")
[ "$MODELS_OK" = 0 ] && problems+=("KYC 模型缺少（確認可連 huggingface.co）")
[ "$FFMPEG_OK" = 0 ] && problems+=("沒有 ffmpeg（請安裝，或執行 npm run deploy:server）")
[ "$CRON_OK" = 0 ] && problems+=("排程寫入失敗")
[ "$DISK_OK" = 0 ] && problems+=("磁碟空間不足")
alert_once "fail-$(join "${problems[@]}" | cksum | cut -d' ' -f1)" 3600 "自動修復後仍有異常：$(join "${problems[@]}")。已執行：$done_msg
最近的服務紀錄：
$(app_logs)"
exit 1
