#!/usr/bin/env bash
# CAFECA 錢包伺服器部署（在跑 cafeca.io 的那台伺服器、app 目錄下執行）
#
#   PUBLIC_ORIGIN=https://cafeca.io npm run deploy:server
#
# 依序：安裝 ffmpeg → 更新程式 → npm install（含 KYC 模型）→ 補齊 .env.local →
#       （需要時）增量部署 IdentityRegistry v2 → 建置 → 重新啟動 → 排程 /api/identity/sync → 檢查
# 每一步都可以重複執行；已完成的步驟會自動略過。
#
# 選項（環境變數）
#   PUBLIC_ORIGIN      對外網址，例 https://cafeca.io（第一次必填，之後從 .env.local 讀）
#   SKIP_PULL=1        不執行 git pull
#   SKIP_IDENTITY=1    不自動執行 npm run deploy -- --identity
#   SKIP_ENTITY=1      不自動執行 npm run deploy -- --entity（法人帳戶合約）
#   SKIP_CRON=1        不建立 /api/identity/sync 的 crontab
#   SKIP_ANCHOR=1      不部署稽核紀錄上鏈合約 AuditAnchor
#   PM2_NAME=cafeca    以 pm2 管理時的程序名稱（預設 cafeca）
#   SYSTEMD_UNIT=xxx   以 systemd 管理時的服務名稱（設定後改用 systemctl restart）
#   PORT=10002         npm start 的埠（與 package.json 一致）
set -euo pipefail

cd "$(dirname "$0")/.."
APP_DIR="$(pwd)"
ENV_FILE="$APP_DIR/.env.local"
PM2_NAME="${PM2_NAME:-cafeca}"
PORT="${PORT:-10002}"

step() { printf '\n\033[1;35m▶ %s\033[0m\n' "$*"; }
ok() { printf '  \033[32m✓\033[0m %s\n' "$*"; }
warn() { printf '  \033[33m!\033[0m %s\n' "$*"; }
die() { printf '  \033[31m✕ %s\033[0m\n' "$*" >&2; exit 1; }

sudo_cmd() { if [ "$(id -u)" -eq 0 ]; then "$@"; elif command -v sudo >/dev/null; then sudo "$@"; else die "需要 root 權限執行：$*"; fi; }

env_get() { [ -f "$ENV_FILE" ] && grep -E "^$1=" "$ENV_FILE" | tail -1 | cut -d= -f2- || true; }
env_set() {
  local k="$1" v="$2"
  touch "$ENV_FILE"
  if grep -qE "^$k=" "$ENV_FILE"; then
    sed -i.bak -E "s|^$k=.*|$k=$v|" "$ENV_FILE" && rm -f "$ENV_FILE.bak"
  else
    printf '%s=%s\n' "$k" "$v" >> "$ENV_FILE"
  fi
}

# ───────────────────────── 1. ffmpeg ─────────────────────────
step "ffmpeg（KYC 解碼臉部影片與音訊）"
if command -v ffmpeg >/dev/null; then
  ok "已安裝：$(ffmpeg -version | head -1)"
else
  if command -v apt-get >/dev/null; then sudo_cmd apt-get update -y && sudo_cmd apt-get install -y ffmpeg
  elif command -v dnf >/dev/null; then sudo_cmd dnf install -y ffmpeg || sudo_cmd dnf install -y ffmpeg-free
  elif command -v yum >/dev/null; then sudo_cmd yum install -y ffmpeg
  elif command -v apk >/dev/null; then sudo_cmd apk add --no-cache ffmpeg
  elif command -v brew >/dev/null; then brew install ffmpeg
  else die "找不到套件管理工具，請手動安裝 ffmpeg，或設定 FFMPEG_PATH"; fi
  command -v ffmpeg >/dev/null || die "ffmpeg 安裝失敗"
  ok "已安裝：$(ffmpeg -version | head -1)"
fi

# ───────────────────────── 2. 程式碼 ─────────────────────────
step "更新程式碼"
if [ "${SKIP_PULL:-}" = "1" ]; then
  warn "SKIP_PULL=1，略過 git pull"
elif git -C "$APP_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  if [ -n "$(git -C "$APP_DIR" status --porcelain --untracked-files=no)" ]; then
    die "工作目錄有未提交的修改，請先處理（或 SKIP_PULL=1 略過）"
  fi
  git -C "$APP_DIR" pull --ff-only
  ok "$(git -C "$APP_DIR" log --oneline -1)"
else
  warn "不是 git 目錄，略過"
fi

# ───────────────────────── 3. 相依套件與模型 ─────────────────────────
step "npm install（postinstall 會下載 MediaPipe 與 KYC 模型，約 140 MB）"
want_node="$(tr -d ' \n' < "$APP_DIR/../.nvmrc" 2>/dev/null || echo 24.22.1)"
if [ "$(node -v 2>/dev/null)" != "v$want_node" ]; then
  # 有 nvm 時自動安裝並切換到指定版本
  if [ -s "${NVM_DIR:-$HOME/.nvm}/nvm.sh" ]; then
    # shellcheck disable=SC1091
    . "${NVM_DIR:-$HOME/.nvm}/nvm.sh"
    nvm install "$want_node" >/dev/null && nvm use "$want_node" >/dev/null
  fi
  [ "$(node -v 2>/dev/null)" = "v$want_node" ] || die "需要 Node.js $want_node（.nvmrc），目前 $(node -v 2>/dev/null || echo 未安裝)。請執行 nvm install $want_node && nvm alias default $want_node"
fi
ok "Node.js $(node -v)"
npm install
npm run fetch-models
missing=0
for f in face_detection_yunet_2023mar.onnx face_recognition_sface_2021dec.onnx face_landmarks_478.onnx ppocrv5_det.onnx ppocrv5_rec.onnx ppocrv5_dict.txt whisper/onnx-community/whisper-base/onnx/encoder_model_quantized.onnx; do
  [ -f "models/kyc/$f" ] || { warn "缺少 models/kyc/$f"; missing=1; }
done
[ "$missing" = 0 ] && ok "KYC 模型齊全" || warn "模型不齊：後台驗證會把案件全部轉人工。請確認伺服器可連 huggingface.co 後重跑 npm run fetch-models"

# ───────────────────────── 4. .env.local ─────────────────────────
step "設定 .env.local"
[ -f "$ENV_FILE" ] || die "找不到 .env.local（部署者私鑰與服務金鑰）。第一次部署請先執行 npm run deploy"
origin="${PUBLIC_ORIGIN:-$(env_get PUBLIC_ORIGIN)}"
[ -n "$origin" ] || die "請提供對外網址：PUBLIC_ORIGIN=https://cafeca.io npm run deploy:server"
origin="${origin%/}"
env_set PUBLIC_ORIGIN "$origin"
ok "PUBLIC_ORIGIN=$origin"
if [ -z "$(env_get KYC_REVIEW_TOKEN)" ]; then
  env_set KYC_REVIEW_TOKEN "$(node -e 'console.log(require("crypto").randomBytes(16).toString("hex"))')"
  ok "已產生 KYC_REVIEW_TOKEN（建立第一位管理者用，見 .env.local；之後人員以 Passkey 登入 $origin/admin）"
else
  ok "KYC_REVIEW_TOKEN 已設定"
fi
if [ -z "$(env_get KYC_PAIRWISE_KEY)" ]; then
  env_set KYC_PAIRWISE_KEY "$(node -e 'console.log(require("crypto").randomBytes(32).toString("hex"))')"
  ok "已產生 KYC_PAIRWISE_KEY（pairwise_id 的 HMAC 金鑰；一旦使用就不可更換，否則依賴方看到的同一人識別碼會全部改變）"
else
  ok "KYC_PAIRWISE_KEY 已設定"
fi
if [ -z "$(env_get CRON_SECRET)" ]; then
  env_set CRON_SECRET "$(node -e 'console.log(require("crypto").randomBytes(24).toString("hex"))')"
  ok "已產生 CRON_SECRET（每日排程 /api/maintenance 用）"
fi
if [ -z "$(env_get DISCLOSURE_SIGNING_KEY)" ]; then
  env_set DISCLOSURE_SIGNING_KEY "$(node -e 'const k=require("crypto").generateKeyPairSync("ec",{namedCurve:"P-256"}).privateKey.export({format:"jwk"});console.log(Buffer.from(k.d,"base64url").toString("hex"))')"
  ok "已產生 DISCLOSURE_SIGNING_KEY（資料調閱資料包的簽章金鑰；更換後依賴方須重新抓取 disclosure.jwks）"
else
  ok "DISCLOSURE_SIGNING_KEY 已設定"
fi
[ -n "$(env_get MOEACA_TEST_ANCHORS)" ] && warn "MOEACA_TEST_ANCHORS 只限自動化測試（會信任測試 PKI 的工商憑證），正式環境請移除"
for k in KYC_PROTOTYPE_AUTO_APPROVE NEXT_PUBLIC_KYC_SIMULATE; do
  [ "$(env_get $k)" = "1" ] && warn "$k=1 只限開發，正式環境請移除"
done
if [ "$(env_get CAFECA_MODE)" = "production" ]; then
  npx tsx scripts/launch-gate.mts || die "CAFECA_MODE=production：上線閘門未通過（見上方），請先移除這些設定"
  ok "正式模式上線閘門通過"
fi
[ "$(env_get KYC_AUTO_APPROVE)" = "1" ] && ok "KYC_AUTO_APPROVE=1（高信心案件自動通過）" || ok "KYC_AUTO_APPROVE 未開啟：所有案件轉人工複核（門檻校準前的預設）"

# ───────────────────────── 5. IdentityRegistry v2 ─────────────────────────
step "IdentityRegistry v2"
dep_file="deployments/boltchain-testnet.local.json"
[ -f "$dep_file" ] || dep_file="deployments/boltchain-testnet.json"
if node -e "process.exit(require('./$dep_file').identityRegistry ? 0 : 1)" 2>/dev/null; then
  ok "已部署：$(node -p "require('./$dep_file').identityRegistry")"
elif [ "${SKIP_IDENTITY:-}" = "1" ]; then
  warn "SKIP_IDENTITY=1，略過（依賴方仍會讀不到 v2）"
else
  warn "尚未部署，執行 npm run deploy -- --identity（需要部署者約 6.5 BOLT）"
  npm run deploy -- --identity
fi

# ───────────────────────── 5b. 法人帳戶合約 ─────────────────────────
step "法人帳戶合約（MemberValidator＋EntityAccountFactory）"
dep_file="deployments/boltchain-testnet.local.json"
[ -f "$dep_file" ] || dep_file="deployments/boltchain-testnet.json"
if node -e "process.exit(require('./$dep_file').entityFactory ? 0 : 1)" 2>/dev/null; then
  ok "已部署：$(node -p "require('./$dep_file').entityFactory")"
elif [ "${SKIP_ENTITY:-}" = "1" ]; then
  warn "SKIP_ENTITY=1，略過（公司帳戶功能不會啟用）"
elif ! node -e "process.exit(require('./$dep_file').identityRegistry ? 0 : 1)" 2>/dev/null; then
  warn "需要先部署 IdentityRegistry v2，略過"
else
  warn "尚未部署，執行 npm run deploy -- --entity（不影響既有身分）"
  npm run deploy -- --entity
fi

# ───────────────────────── 5c. 稽核紀錄上鏈合約 ─────────────────────────
step "稽核紀錄上鏈（AuditAnchor）"
dep_file="deployments/boltchain-testnet.local.json"
[ -f "$dep_file" ] || dep_file="deployments/boltchain-testnet.json"
if node -e "process.exit(require('./$dep_file').auditAnchor ? 0 : 1)" 2>/dev/null; then
  ok "已部署：$(node -p "require('./$dep_file').auditAnchor")"
elif [ "${SKIP_ANCHOR:-}" = "1" ]; then
  warn "SKIP_ANCHOR=1，略過（稽核紀錄不會每日上鏈）"
else
  warn "尚未部署，執行 npm run deploy -- --anchor"
  npm run deploy -- --anchor
fi

# ───────────────────────── 6. 建置 ─────────────────────────
step "npm run build（合約地址在建置時寫入，部署合約後一定要重新建置）"
npm run build

# ───────────────────────── 7. 重新啟動 ─────────────────────────
step "重新啟動"
if [ -n "${SYSTEMD_UNIT:-}" ]; then
  sudo_cmd systemctl restart "$SYSTEMD_UNIT"
  ok "systemctl restart $SYSTEMD_UNIT"
elif command -v pm2 >/dev/null; then
  if pm2 describe "$PM2_NAME" >/dev/null 2>&1; then pm2 restart "$PM2_NAME" --update-env
  else pm2 start npm --name "$PM2_NAME" -- start; fi
  pm2 save >/dev/null 2>&1 || true
  ok "pm2：$PM2_NAME"
else
  warn "沒有 pm2 也沒有設定 SYSTEMD_UNIT：請用你平常的方式重新啟動 npm start（或 npm i -g pm2 後重跑）"
fi

# ───────────────────────── 8. 排程 ─────────────────────────
step "排程 /api/identity/sync（恢復後重新簽發或暫停實名證明）與 /api/entity/sync（法人每日監控）"
cron_line="*/5 * * * * curl -fsS -X POST $origin/api/identity/sync > /dev/null 2>&1 # cafeca-identity-sync"
cron_entity="17 3 * * * curl -fsS -X POST $origin/api/entity/sync > /dev/null 2>&1 # cafeca-entity-sync"
cron_maint="41 3 * * * curl -fsS -X POST -H 'x-cafeca-cron: $(env_get CRON_SECRET)' $origin/api/maintenance > /dev/null 2>&1 # cafeca-maintenance"
if [ "${SKIP_CRON:-}" = "1" ]; then
  warn "SKIP_CRON=1，略過"
elif command -v crontab >/dev/null; then
  ( crontab -l 2>/dev/null | grep -v "# cafeca-identity-sync" | grep -v "# cafeca-entity-sync" | grep -v "# cafeca-maintenance" ; echo "$cron_line" ; echo "$cron_entity" ; echo "$cron_maint" ) | crontab -
  ok "crontab：身分同步每 5 分鐘、法人商工登記監控每天 03:17、同意逾期、保存期限清除與稽核紀錄上鏈每天 03:41"
else
  warn "沒有 crontab，請自行每 5 分鐘呼叫：curl -X POST $origin/api/identity/sync"
fi

# ───────────────────────── 9. 檢查 ─────────────────────────
step "檢查"
cfg=""
for i in $(seq 1 30); do
  cfg="$(curl -fsS "http://127.0.0.1:$PORT/.well-known/cafeca-configuration" 2>/dev/null || true)"
  [ -n "$cfg" ] && break
  sleep 2
done
if [ -z "$cfg" ]; then
  warn "本機 http://127.0.0.1:$PORT 沒有回應，請確認服務已啟動"
else
  echo "$cfg" | node -e '
    let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{
      const c=JSON.parse(s), want=process.argv[1];
      const line=(ok,t)=>console.log(`  ${ok?"\x1b[32m✓\x1b[0m":"\x1b[31m✕\x1b[0m"} ${t}`);
      line(c.issuer===want, `issuer ${c.issuer}`);
      line(!!c.chain?.rpc && !/boltchain\.cafeca\.io/.test(c.chain.rpc), `chain.rpc ${c.chain?.rpc}`);
      line(!!c.contracts?.identityRegistry, `contracts.identityRegistry ${c.contracts?.identityRegistry}`);
    });' "$origin"
fi
curl -fsS -X POST "http://127.0.0.1:$PORT/api/identity/sync" >/dev/null 2>&1 && ok "/api/identity/sync 可呼叫" || warn "/api/identity/sync 呼叫失敗"
idx="$(curl -fsS "http://127.0.0.1:$PORT/api/index/status" 2>/dev/null || true)"
if [ -n "$idx" ]; then
  echo "$idx" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{const j=JSON.parse(s);const lag=j.head==null?null:j.head-j.lastBlock;console.log(`  ${lag!==null&&lag<50?"\x1b[32m✓\x1b[0m":"\x1b[33m!\x1b[0m"} 事件索引：同步到 #${j.lastBlock}／鏈高 #${j.head}，${j.events} 筆事件${j.lastError?"，錯誤："+j.lastError:""}`)})'
else
  warn "/api/index/status 沒有回應"
fi
printf '\n完成。對外檢查：curl -s %s/.well-known/cafeca-configuration\n' "$origin"
