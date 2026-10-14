# CAFECA 數位身分錢包（Next.js 16 原型）

以 FIDO2 金鑰為身分根（不需第三方登入）、Passkey 與 CAFECA 卡操作的智能合約錢包，整合端對端加密聊天、聊天內支付、AI 子錢包與 Visa 支出通道。部署在 Boltchain 測試網（chainId 8018）。

## 啟動

```bash
npm install          # 會一併下載 MediaPipe 臉部模型到 public/mediapipe（npm run fetch-models 可重跑）

# 1. 第一次執行：自動產生部署者私鑰與所有服務金鑰（寫入 .env.local），並印出部署者地址
npm run deploy

# 2. 轉入至少 8 BOLT 到印出的部署者地址，再執行一次即開始部署
npm run deploy

npm run dev   # http://localhost:10002
npm run demo:signin   # 選用：第三方登入範例網站 http://localhost:10003
```

**IdentityRegistry v2（規格 §16.2）**：已經部署過的環境執行 `npm run deploy -- --identity`，只增量部署 v2、把 v1 仍有效的證明遷移過去，並重新部署改讀 v2 的 paymaster（會取回舊 paymaster 的押金，需要約 6.5 BOLT）。工廠與 KeyringValidator 不動，既有身分地址不變。完成後重新啟動 `npm run dev`／`npm start`。

- 身分恢復執行後，由 `POST /api/identity/sync` 重新簽發或暫停 v2 證明。恢復頁面會自動觸發；正式環境請再加排程（例如每 5 分鐘 `curl -X POST https://<網域>/api/identity/sync`）。
- 部署在反向代理後方時設定 `PUBLIC_ORIGIN=https://<網域>`；公開 RPC 預設為 `<PUBLIC_ORIGIN>/api/rpc`，可用 `PUBLIC_RPC_URL` 覆寫。
- `KYC_SIGNER_CLASS=PRODUCTION` 只在正式 KYC 後台上線、換上 HSM 金鑰後使用；原型期維持預設（PROTOTYPE）。

已經部署過、之後合約有變更（例如 v0.3 金鑰模型）時，`npm run deploy` 會補上缺少的服務金鑰（`GUARDIAN_ROOT_KEY`、`GUARDIAN_SEED`）並整套重新部署；舊身分不會搬到新合約，需重新建立。只改了工廠合約時可用 `npm run deploy -- --factory`。

Passkey 需要安全環境：本機請用 `http://localhost:10002`，其他網域須為 https。

## 伺服器部署（cafeca.io）

在伺服器的 `app` 目錄執行一個指令即可（可重複執行，已完成的步驟會略過）：

```bash
PUBLIC_ORIGIN=https://cafeca.io npm run deploy:server
```

依序完成：

1. 安裝 `ffmpeg`（apt／dnf／yum／apk／brew，需要 sudo）
2. `git pull --ff-only`
3. `npm install`（含 MediaPipe 與 KYC 模型，約 140 MB，需能連 huggingface.co）
4. `.env.local`：寫入 `PUBLIC_ORIGIN`；沒有 `KYC_REVIEW_TOKEN`（建立第一位管理者用）就產生一組；提醒開發用旗標，`CAFECA_MODE=production` 時上線閘門不通過就停止
5. 尚未部署 IdentityRegistry v2 時執行 `npm run deploy -- --identity`（部署者需約 6.5 BOLT）
6. `npm run build`（合約地址在建置時寫入）
7. 重新啟動：有 pm2 用 `pm2 restart cafeca`（沒有就 `pm2 start npm --name cafeca -- start`），或 `SYSTEMD_UNIT=<服務名>` 改用 systemctl
8. crontab 每 5 分鐘呼叫 `POST /api/identity/sync`
9. 檢查 `/.well-known/cafeca-configuration` 的 `issuer`、`chain.rpc`、`contracts.identityRegistry`

選項：`SKIP_PULL=1`、`SKIP_IDENTITY=1`、`SKIP_CRON=1`、`PM2_NAME=<名稱>`、`SYSTEMD_UNIT=<服務>`、`PORT=<npm start 的埠，預設 10002>`。

第一次部署（還沒有 `.env.local`）請先照上面「啟動」執行 `npm run deploy` 產生金鑰並部署合約。

## 功能對照

| 頁面 | 功能 | 規格章節 |
| --- | --- | --- |
| `/` | Landing page：數位身分證是什麼、為什麼需要、怎麼使用、三種金鑰與備援金鑰被盜的緩解、FAQ | — |
| `/start` | 建立身分：在裝置建立 FIDO2 金鑰 → 地址＝CREATE2(公鑰) → 一筆 UserOp 完成部署＋登記聊天裝置；裝置已有金鑰則直接登入 | §3、§4.4 |
| `/link` | 新裝置加入既有身分：建立金鑰 → 配對碼／QR → 在已登入的裝置確認，所有裝置金鑰同級 | §4.2 |
| `/kyc` | 實名驗證：身分證件照片＋引導式臉部影像（轉頭、眨眼、念隨機數字）→ 送出後顯示送出的證件與審核進度（不顯示臉部影片）（審核中不能重送，退件才能重拍）→ L2 證明 → 安裝平台備援金鑰 | §3.4、§5.3 |
| `/wallet` | TWDC 與 BOLT 餘額、轉帳（即時預覽需要手機或卡片）、收款 QR、測試幣、額度、紀錄；BOLT 預設可轉帳：新版工廠開戶時即設定平台預設 BOLT 額度（每筆 10、每日 50 BOLT，部署時讀 `NATIVE_DEFAULT_PER_TX`／`NATIVE_DEFAULT_DAILY`）；舊工廠建立、BOLT 額度為 0 的帳戶可在錢包內啟用（v2 由管理者帳戶代為設定；v1 由帳戶自己設定，綁卡即時、否則排程 72 小時，bundler 只放行這一種自行設定） | §4.3 |
| `/card` | 完成 KYC 後付費購買實體卡（TWDC 付款給發卡方）→ 綁定、掛失補發、Visa 通道、POS 刷卡模擬 | §4.5、§6.4、§9 |
| `/agents` | AI 代理與支出通道、x402 商家購買、超額 intent 以卡片核准、撥款、撤銷 | §6 |
| `/chat` | 「＋」選單：轉帳、收款、相機、檔案（10 MB 內，本機加密後才上傳）、分享位置（確認後才送出）；代稱（第一次設定免費、之後固定，變更需付 150 TWDC，舊代稱保留）、裝置金鑰上鏈、E2EE 訊息、付款請求與聊天內付款、AI 核准通知 | §7 |
| `/security` | 資料調閱紀錄（誰依什麼依據調閱了哪些實名資料，當事人同意類以 Passkey 回覆）、裝置金鑰（同級、可互相移除）、實體卡與平台備援金鑰（不可移除）、連結其他裝置、額度（唯讀）、恢復狀態與取消、登出 | §4、§5 |
| `/company` | 公司帳戶：建立（你成為第一位管理者）、以統編申請商工登記驗證（代表人本人自動通過，否則上傳授權書）、成員（管理者／經辦）、代公司轉帳；登入網站時可選「以公司身分」 | §16.4 |
| `/admin/entity` | 法人驗證人工複核：商工登記資料、申請人與代表人比對、授權書；核准後簽發法人證明 | §16.4 |
| `/admin` | 管理後台首頁：以人員 Passkey 登入，依角色列出功能；`/admin/staff` 人員管理（邀請、角色、Passkey、停用），`/admin/join` 受邀者加入 | §16.6 P3 |
| `/admin/rp` | 依賴方登記：名稱、統編、網域、法遵聯絡人、加密公鑰；API 金鑰只在建立時顯示一次；可停用 | §16.6 P2 |
| `/admin/disclosures` | 資料調閱雙人覆核：法律依據、客戶關係證明、當事人同意、資料預覽；第一位核准欄位、第二位（不同人）放行或退件 | §16.6 P2 |
| `/admin/audit` | 稽核紀錄（hash-chained）：查詢與整條鏈驗證，竄改或刪除任一筆都會指出位置 | §16.6 P2 |
| `/admin/limits` | 交易額度管理（只給管理者）：查詢帳戶額度與今日已用、調升或調降（原因碼＋備註必填）、鏈上調整紀錄 | §4.3 |
| `/dl/auth` | Sign in with CAFECA：第三方網站免註冊登入（彈出視窗／整頁導向／跨裝置 QR），顯示網域與第一次連線提醒、可取消提供的資料；`/security` 列出登入過的網站。串接說明見[根目錄 README](../README.md#sign-in-with-cafeca第三方網站登入串接) | §15 |
| `/dl/sign` | 簽章通道：登入時同意開啟後，網站可請你簽署訊息、EIP-712 或付款；並列顯示網站說明與錢包解析的實際內容，逐筆確認；跨裝置經加密中繼，錢包開啟時跳出提示；`/security` 可關閉通道 | §15.8 |
| `/recover` | 找到身分 → 新裝置建立金鑰 → 實體卡立即新增，或以證件＋臉部影像讓平台備援金鑰發起恢復（48h／有卡 7 天） | §5 |

## 架構

```
瀏覽器
 ├─ Passkey（WebAuthn，裝置金鑰：每台裝置同級）
 ├─ 卡片模擬器（WebCrypto 不可匯出 P-256，實體卡金鑰，CTXD 螢幕確認）
 ├─ 聊天裝置金鑰（ECDH P-256 → AES-GCM）
 └─ /api/rpc（唯讀 RPC 代理）

Next.js Route Handlers（伺服器）
 ├─ /api/bundler     組 UserOp、paymaster 簽章、handleOps 送出
 ├─ /api/auth        ERC-1271 登入挑戰 → session cookie
 ├─ /api/signin      /.well-known/cafeca-configuration（第三方登入探索文件）
 ├─ /api/identity    恢復後的實名證明同步（IdentityRegistry v2 重新簽發或暫停）
 ├─ /api/channel     簽章通道中繼信箱（只存端對端加密的密文）
 ├─ /api/issuer      發卡方簽署卡片證明
 ├─ /api/kyc         模擬 KYC 單位（證件＋臉部影像、活體挑戰）
 ├─ /api/recovery    平台備援金鑰（模擬 HSM）：重新驗證本人後簽署恢復
 ├─ /api/card        實體卡訂單（核對鏈上付款）
 ├─ /api/visa        模擬發卡處理商（authorize／capture）
 ├─ /api/agent       AI 代理（規則式，金鑰代表 TEE）
 ├─ /api/merchant    x402 商家
 └─ /api/chat        密文轉存

Boltchain 測試網：EntryPoint v0.8 ＋ CAFECA 合約（../contracts）
```

## 測試網替代方案（上線前必須換掉）

| 項目 | 測試網做法 | 正式版 |
| --- | --- | --- |
| 身分建立防濫用 | 每 IP 每日 10 個身分（`MAX_IDENTITIES_PER_IP_PER_DAY`） | 裝置認證（App Attest／Play Integrity）＋Redis |
| CAFECA 卡 | 瀏覽器卡片模擬器 | 實體卡（安全晶片驅動電子紙） |
| KYC 擷取 | 證件即時拍攝（引導框偵測、自動拍攝、裝置端浮水印）＋6 動作活體（MediaPipe 臉部特徵點）；上傳只有浮水印版 | 同左，並加原生 App 裝置認證 |
| KYC 後台 | 自建驗證已接上（OCR、活體重檢、語音、人臉比對、證號重複）；自動通過預設關閉，全部轉人工複核 `/admin/kyc` | 以真實樣本校準門檻後開啟 `KYC_AUTO_APPROVE=1`；補翻拍／深偽分類器、ISO 30107-3 送測、領補換查詢 |
| 平台備援金鑰 | 由 `GUARDIAN_SEED`＋帳戶地址衍生 | 每帳戶於 HSM 內產生、不可匯出，簽署需雙人覆核 |
| 平台根金鑰 | `.env.local` 的 `GUARDIAN_ROOT_KEY` | 離線冷儲存（多簽） |
| 重新 KYC 恢復 | 新裝置重新即時拍證件＋6 動作活體；統一編號 HMAC 相同且人臉相似度 ≥ 0.45 才發起恢復，否則轉人工 | 同左，並加原生 App 裝置認證 |
| KYC／Visa | 模擬 | 持照 KYC 單位、發卡處理商 |
| AI 代理金鑰 | 伺服器 `data/store.json` | TDX enclave |
| 聊天 | ECDH＋AES-GCM | MLS（RFC 9420） |
| 資料儲存 | `data/store.json` | 資料庫 |
| Bundler | 內建（不套用 ERC-7562 限制） | 獨立 bundler 或原生 AA |

## 開發

```bash
npm run typecheck
npx eslint src
npm run build
```

合約 ABI 在 `src/lib/contracts/abis.ts`，部署用 bytecode 在 `scripts/artifacts/`，都由 `../contracts` 編譯產生。

## KYC 後台驗證（規格 §14.3、§14.6）

證件與臉部影像只在自己的伺服器上以 onnxruntime-node 推論，不送往任何第三方；只處理浮水印版影像。

| 模組 | 做法 | 模型（Apache-2.0，由 `npm run fetch-models` 下載到 `models/kyc`，約 140 MB） |
| --- | --- | --- |
| 證件 OCR | 文字偵測＋辨識 → 依標籤列取姓名、出生日期、性別、發證日期、住址；統一編號以檢查碼驗證 | PP-OCRv5 mobile（繁簡中文） |
| 欄位合理性 | 檢查碼、性別與統一編號第二碼、日期範圍 | — |
| 活體重檢 | 影片每秒 8 格：YuNet 找臉 → 478 點特徵 → 與裝置端相同公式的頭部轉向、眼睛與嘴巴開合；逐一核對 6 個動作在裝置回報的時間窗內真的出現 | YuNet、MediaPipe 臉部 478 點（與裝置端同一份權重的 ONNX 版） |
| 念數字 | 只取念數字那段音訊，Whisper 辨識後比對 4 位數字（中文、大寫數字、英文都可） | Whisper base（int8） |
| 人臉比對 | 影片最正面的一格 vs 證件照，SFace 餘弦相似度 | YuNet、SFace |
| 證號重複 | 統一編號 HMAC 是否已綁定其他 CAFECA 身分 | — |

**決策**

- 明確不是同一人（相似度 < 0.15）或影片中幾乎沒有臉 → 退件，使用者可重拍。
- 全部通過且相似度 ≥ `KYC_AUTO_FACE`（預設 0.45），並且 `KYC_AUTO_APPROVE=1` → 自動通過。
- 其他一律轉人工複核。**`KYC_AUTO_APPROVE` 預設關閉**：門檻用真實（經同意的）樣本校準前，所有案件都由人審，複核紀錄與分數就是校準資料。

**人工複核後台 `/admin/kyc`**：需要「KYC 與法人複核」角色（見下方「管理後台人員」）。可以看到浮水印版證件、臉部影片、每項檢查、擷取欄位與分數，然後核准或退件。每次登入、檢視檔案與決策都寫入稽核紀錄 `data/audit/audit.jsonl`（見下方「稽核紀錄」；P2 以前的舊紀錄留在 `data/kyc/review-log.jsonl`）。核准開戶案件＝寫入 L2；核准恢復案件＝以平台備援金鑰發起恢復。

**KYC Credential（規格 §16.3）**：第三方登入要求 `legal_name`、`doc_type`、`nationality`、`pairwise_id` 時，同意畫面向 `/api/kyc/credential` 取得由 KYC 簽章者簽署、綁定網站與這次登入 nonce 的 credential（`src/server/kyc-credential.ts`）。資料來自最新一筆核准案件的擷取欄位。`pairwise_id` 使用 `.env.local` 的 `KYC_PAIRWISE_KEY`（`npm run deploy`／`deploy:server` 會自動產生）；**這把金鑰一旦有網站使用就不能更換**，否則所有網站看到的同一人識別碼都會改變。沒有設定時不提供 `pairwise_id`。

**交易額度只能由管理者調整**：KeyringValidator v2 的 `setLimits` 與排程修改額度一律拒絕（實體卡也不行），只有 `limitAdmin` 能呼叫 `setLimitsFor(account, token, perTx, daily, reason)`，每次調整發出 `LimitsSetByAdmin`。測試網 `limitAdmin`＝部署者（營運錢包），正式環境請以 `transferLimitAdmin`／`acceptLimitAdmin` 移交給多簽。管理後台 `/admin/limits` 需要「交易額度」角色，每次查詢與調整都寫入稽核紀錄。

> **已部署的測試網仍是 v1。** v1 的額度寫在使用者帳戶可自行修改的位置，管理者無法調整；目前由 bundler 拒絕贊助任何修改額度的操作（暫時防護，自備 BOLT 直接送交易仍可繞過）。要換成 v2 必須重新部署帳戶相關合約（`npm run deploy`，KeyringValidator 與工廠都會換新），**既有測試網身分的地址會改變、需要重新開戶**。

**法人帳戶（規格 §16.4）**：`MemberValidator`（成員代簽、額度只能由管理者調整）＋`EntityAccountFactory`。已部署的環境執行 `npm run deploy -- --entity` 增量部署，不影響既有身分（`deploy:server` 會自動執行）。商工登記以 `data.gcis.nat.gov.tw` 查詢（測試可用 `GCIS_COMPANY_URL` 指向模擬服務），每日監控由排程呼叫 `POST /api/entity/sync`；`/api/entity/sync?force=1` 需管理後台登入，立即重查全部法人。

**鏈上事件索引（規格 §16.6 P0-d）**：伺服器持續同步 TWDC 轉帳、金鑰增減、實名證明狀態、恢復、額度調整與法人帳戶事件（`src/server/indexer.ts`，存在 `data/index/`，可隨時刪除重建）。錢包紀錄、聊天中的轉帳、「以此裝置的 Passkey 登入」反查身分與管理後台都改讀索引，瀏覽器不再從部署區塊掃描整條鏈（Boltchain RPC 的 `eth_getLogs` 每次最多 10,000 個區塊）。每次同步把所有合約合併成一個查詢、每段 ≤ 10,000 區塊，並重掃最後 5 個區塊去重；部署位址改變時自動重建。API：`GET /api/index/transfers?address=&limit=&before=`、`GET /api/index/key-accounts?keyId=`、`GET /api/index/status`（`deploy:server` 會檢查同步落後）。

**工商憑證綁定（P1.5 PoC）**：`/company` 的「以工商憑證綁定」透過使用者電腦上的 HiPKI 跨平台網頁元件（`http://localhost:61161`，`src/lib/hipki.ts`）以 IC 卡簽署 PKCS#7；伺服器 `src/server/moeaca.ts` 驗證簽章、憑證鏈（內建 GRCA／GRCA G3 根與 MOEACA 第二、三代中繼，`src/server/moeaca-anchors.ts`）、效期、金鑰用途、憑證政策 `2.16.886.101.0.3.3` 與分區 CRL，取出統一編號與正卡／附卡。憑證欄位已以 MOEACA 公開下載的真實憑證核對；元件的 postMessage 參數與錯誤碼依公開範例實作，**尚待以實體卡片與讀卡機確認**。可用 `npm run moeaca:inspect -- <憑證.cer>` 檢查一張實體卡的憑證，或 `--sig <PKCS#7> --tbs <內容>` 檢查元件產生的簽章。`MOEACA_TEST_ANCHORS` 只供自動化測試使用測試 PKI，正式環境不得設定。

**管理後台人員（規格 §16.6 P3-A3）**：`/admin` 每位人員一個帳號、以自己的 Passkey 登入（與錢包的 Passkey 分開），稽核紀錄的操作人是「姓名（人員 id）」。

- 第一位管理者：還沒有任何啟用中的管理者時，`/admin` 會要求 `.env.local` 的 `KYC_REVIEW_TOKEN`（部署時自動產生），並在這台裝置建立 Passkey。之後這個密碼就不能再登入。**升級到這一版後，第一位打開 `/admin` 並輸入密碼的人就是管理者，請盡快完成。**
- 其他人員：管理者在 `/admin/staff` 產生邀請連結（72 小時、一次性），受邀者在自己的裝置建立 Passkey。遺失裝置時由管理者發「新增 Passkey」邀請，或移除舊的 Passkey、停用帳號。
- 角色：`admin`（人員與依賴方管理）、`kyc`（KYC 與法人複核）、`disclosure`（資料調閱核准）、`limits`（交易額度）、`audit`（稽核紀錄唯讀）。管理者不會自動擁有其他角色；資料調閱需要兩位不同的人員具備 `disclosure`。
- 伺服器端驗證 WebAuthn：challenge（5 分鐘、一次性）、來源網址（正式模式只接受 `PUBLIC_ORIGIN`）、rpId、使用者驗證旗標與 ES256 簽章。停用與角色調整立即生效。

**正式模式上線閘門（P3-A4）**：`.env.local` 設定 `CAFECA_MODE=production` 後，伺服器啟動與 `deploy:server` 都會檢查，以下任一項存在就拒絕啟動：`KYC_PROTOTYPE_AUTO_APPROVE`、`NEXT_PUBLIC_KYC_SIMULATE`、`MOEACA_TEST_ANCHORS`、`GCIS_COMPANY_URL`、未校準的 `KYC_AUTO_APPROVE`（校準後另設 `KYC_AUTO_CALIBRATED=1`）、非 https 的 `PUBLIC_ORIGIN`、未設定 `CRON_SECRET`。可先執行 `npm run gate` 自行檢查。正式簽章者只會在閘門通過的環境登記。

**伺服器金鑰介面（P3-A1）**：KYC 簽章（`Attested`／`Suspended`／`Revoked`、`KycCredential`）、資料包 ES256 簽章與 `pairwise_id` 的 HMAC 一律經過 `src/server/keys.ts`。`KEY_BACKEND=local`（預設）從 `.env.local` 讀金鑰；改用 KMS／HSM 時新增一個實作並在 `BACKENDS` 註冊，其他程式不用改。KMS 回傳的 secp256k1 簽章多半是 DER、可能是 high-s，請用 `secp256k1FromDer` 轉換（OpenZeppelin ECDSA 拒收 high-s）。發卡方、備援金鑰根金鑰、paymaster 等其他金鑰尚未移入這個介面。

**HSM（PKCS#11，P3-A1）**：`KEY_BACKEND=pkcs11` 時，KYC 簽章（secp256k1）、資料包簽章（P-256）與 pairwise HMAC 都在 HSM 內執行，金鑰在 HSM 產生、不可匯出、只能簽章（`src/server/keys-pkcs11.ts`）。設定：

| 變數 | 說明 |
| --- | --- |
| `PKCS11_MODULE` | HSM 廠商的 PKCS#11 函式庫路徑（測試用 SoftHSM：`/usr/lib/softhsm/libsofthsm2.so`） |
| `PKCS11_TOKEN_LABEL`、`PKCS11_PIN` | token（partition）名稱與使用者 PIN |
| `PKCS11_KYC_SIGNER_LABEL`、`PKCS11_PAIRWISE_LABEL`、`PKCS11_DISCLOSURE_LABEL` | 目前使用的金鑰 label（由 cutover 自動寫入） |

從 `.env.local` 的金鑰換到 HSM：先設好 `PKCS11_MODULE`、`PKCS11_TOKEN_LABEL`、`PKCS11_PIN` 與 `KEY_BACKEND_NEXT=pkcs11`，`npm run cutover -- prepare` 會在 HSM 內產生下一把簽章金鑰、新的 pairwise 金鑰與資料包簽章金鑰，`npm run hsm -- status` 檢查每把金鑰存在、不可匯出並做一次簽章自我測試；之後照下面的切換步驟 `execute`，完成後 `.env.local` 改為 `KEY_BACKEND=pkcs11`，明文金鑰移除（備份檔確認後請安全刪除）。正式模式的上線閘門要求簽章金鑰在 HSM。`pkcs11js` 是 optionalDependency（原生模組，伺服器需要編譯工具），沒有 HSM 的環境安裝失敗也不影響。已用 SoftHSM 完成演練；實體 HSM 請確認廠商支援 secp256k1（`CKM_ECDSA` 搭配 OID 1.3.132.0.10）。

**切換正式 KYC 簽章者（P3-A5）**：

1. `npm run cutover -- prepare`：產生下一把簽章金鑰與新的 pairwise 金鑰（`.env.local` 的 `NEXT_KYC_SIGNER_KEY`、`NEXT_KYC_PAIRWISE_KEY`），印出新簽章者位址。
2. `npm run cutover -- plan`：列出會以新簽章者重新簽發的帳戶（案件由自動驗證或人工複核核准；法人經人工或工商憑證驗證），以及需要重新驗證的帳戶（原型期放行）。不送任何交易。
3. `npm run cutover -- execute`：上線閘門必須通過。依序登記新簽章者為 PRODUCTION（v1、v2）→ 重新簽發 → 標記需要重新驗證並把 v1 降為 L0 → 移除舊簽章者（原型期證明在鏈上降為 L0）→ `.env.local` 換成新金鑰（舊檔備份為 `.env.cutover-<時間>.local`）。每一步都可重跑。治理權在多簽時，會印出要由多簽送出的交易，送出後再重跑。
4. 重新啟動服務。需要重新驗證的使用者在 `/kyc` 會看到提示；pairwise 金鑰一併更換，依賴方先前拿到的 `pairwise_id` 全部失效，請事先通知。

本機演練可加 `--skip-gate`（只允許連到本機 RPC）。

**治理權移交多簽（P3-A2）**：

1. 準備 2 到 5 位成員的 EOA（各自保管，建議硬體錢包，不放在伺服器）。
2. `npm run multisig -- deploy --owners 0xA,0xB,0xC --threshold 2`：部署 `CafecaMultisig`。
3. `npm run multisig -- handover`：部署者把 IdentityRegistry 治理權（兩段式）與 AuditAnchor 管理權交給多簽，並產生「多簽接受治理權」的提案檔（`data/multisig/`）。營運錢包仍是 anchorer，每日上鏈照常。
4. 各成員在自己的裝置 `MULTISIG_SIGNER_KEY=0x… npm run multisig -- sign <提案檔>`，達門檻後 `npm run multisig -- execute <提案檔>`。
5. 之後登記或移除 KYC 簽章者都要多簽：`npm run cutover -- execute` 遇到多簽會印出 `npm run multisig -- propose …`，執行、簽署後重跑即可。`npm run multisig -- status` 查看目前狀態。

額度管理權（`limitAdmin`）預設**不**移交：`/admin/limits` 由營運錢包直接調整，移交後後台無法調整。要移交請加 `handover --limits`。v1 AttestationRegistry 的治理權是 immutable，只能留在部署者（只影響綁卡門檻，依賴方讀 v2）。

**依賴方資料調閱（規格 §16.6 P2）**：依賴方（交易所等）平常只拿得到使用者同意提供的 claims；遇到洗錢防制調查或司法機關調閱，才以這個 API 申請 CAFECA 保存的實名資料（`src/server/disclosure.ts`）。

1. CAFECA 在 `/admin/rp` 登記依賴方與其 P-256 加密公鑰（對方以 `npm run rp -- keygen` 產生，私鑰自己保管），發給 API 金鑰（只存 SHA-256）。
2. 依賴方 `POST /api/rp/disclosures`（`Authorization: Bearer cafeca_rp…`）：

   ```json
   { "account": "0x…", "fields": ["legal_name", "kyc_history", "doc_images"],
     "legalBasis": { "type": "aml", "ref": "文號", "text": "依據說明" },
     "reason": "調閱原因", "caseRef": "內部案號",
     "signIn": { "…": "該帳戶登入你網站時的 SignIn 回應" } }
   ```

   `fields`：`legal_name`、`birthday`、`sex`、`doc_type`、`nationality`、`issue_date`、`kyc_history`、`doc_images`（浮水印版）、`entity`（法人統編、名稱、成員、代簽紀錄）。`legalBasis.type`：`court`、`prosecutor`、`police`、`aml`、`consent`。`aml` 與 `consent` 必須證明對方是自己的客戶：附上 `signIn`（網域須是登記的網域）或 `pairwiseId`。只有 `court`／`prosecutor`／`police` 可以帶 `deferNoticeUntil`（一年內）暫緩通知當事人。
3. `consent` 類先由使用者在 `/security` 的「資料調閱紀錄」以 Passkey 同意或拒絕（ERC-1271 簽章存證）。
4. 複核人員在 `/admin/disclosures` 雙人覆核：第一位核准（可刪減欄位），第二位不同的人放行。
5. 依賴方 `GET /api/rp/disclosures?id=` 取得狀態；放行後 7 天內附 `package`：以依賴方公鑰加密的 JWE（`ECDH-ES`＋`A256GCM`），內容是 CAFECA 以 `DISCLOSURE_SIGNING_KEY` 簽章的 JWS（`ES256`），驗章公鑰公布在 `/.well-known/cafeca-configuration` 的 `disclosure.jwks`。參考實作：`CAFECA_RP_KEY=… npm run rp -- fetch <錢包網址> <id> rp-key.json out/`（解密、驗章、另存證件影像）。
6. 使用者在 `/security` 看得到誰、依什麼依據、調閱了哪些欄位；暫緩通知的案件到期後才顯示。

**時限、同意期限與資料處理約定（P3-B3／B4）**：依賴方登記時必須填寫雙方簽署的 DPA 版本與日期，未登記的依賴方 API 回 403（`POST /api/admin/rp { id, dpaVersion, dpaSignedAt }` 可補登）。每件申請有回應期限 `dueAt`：洗錢防制與同意類（同意後起算）預設 5 個工作天；司法機關可帶 `respondBy`（文書所載期限），沒帶則 5 個工作天。同意請求 7 天未回覆即失效（視為不同意）。逾期案件在 `/admin/disclosures` 標示。

**保存期限（P3-B5）**：未通過的案件、以及被較新核准案件取代的舊案件，180 天後清除證件影像、臉部影片與人臉特徵（保留案件紀錄與檔案雜湊，清除寫入稽核紀錄）；目前依據的核准案件、調閱與稽核紀錄不自動刪除。每日排程 `POST /api/maintenance`（帶 `x-cafeca-cron: $CRON_SECRET`，`deploy:server` 會產生密鑰並建立 crontab）同時處理同意逾期。`/admin/policy` 顯示目前的數值與即將清除的案件。

**條款同意版本（P3-B2）**：服務條款與隱私權告知放在 `content/terms/<版本>/{terms,privacy}.md`，`TERMS_VERSION` 指定目前版本（預設草案 `draft-2026-09`），`/terms`、`/privacy` 顯示目前版本與內容雜湊。登入後未同意目前版本（版本號或內容雜湊不同都算）時，App 內頁只顯示條款；使用者以 Passkey 簽署「版本＋內容雜湊＋帳戶」（ERC-1271 驗證），簽章存證並寫入稽核紀錄，「安全」頁列出同意紀錄。實名驗證送件要求已同意目前版本（未同意回 428）。定稿後新增一個版本資料夾並改 `TERMS_VERSION`，所有人都會被要求重新同意。

> 以上天數都是**給法律顧問審閱的草案預設值**（`src/server/policy.ts`），可用 `DISCLOSURE_SLA_AML_DAYS`、`DISCLOSURE_SLA_AUTHORITY_DAYS`、`DISCLOSURE_CONSENT_DAYS`、`DISCLOSURE_PACKAGE_DAYS`、`RETENTION_REJECTED_CASE_DAYS`、`RETENTION_SUPERSEDED_CASE_DAYS` 調整；法遵定案後設 `POLICY_APPROVED=1` 與 `POLICY_VERSION`。工作天尚未計入國定假日；帳戶關閉後的保存年限、服務條款同意版本的紀錄，待條款定稿後實作。

`DISCLOSURE_SIGNING_KEY` 由 `npm run deploy`／`deploy:server` 自動產生；更換後依賴方要重新抓 `disclosure.jwks`。法人帳戶目前不接受 `consent` 類申請。

> **上線前須由法遵確認**：依賴方服務條款與資料處理約定（DPA）、各類法律依據的審核標準（文件真偽查核、必要欄位最小化）、暫緩通知的條件、資料包與稽核紀錄的保存期限，以及個資法第 8／9 條告知與第 20 條目的外利用的處理方式。目前的流程與欄位是技術原型。

**稽核紀錄**：複核後台登入、檢視證件、KYC 決策、法人驗證、額度調整、依賴方登記與資料調閱每個步驟都寫入 `data/audit/audit.jsonl`。每筆含 `seq`、`prev`（上一筆 hash）與 `hash = SHA-256(prev ‖ 正規化 JSON)`，`/admin/audit` 每次開啟都重新驗證整條鏈。每日排程會把（筆數, 最新 hash）寫進 `AuditAnchor` 合約（P3-A6，`npm run deploy -- --anchor` 增量部署，`deploy:server` 會自動執行）：hash 鏈只能證明沒有被改一筆，鏈上錨點連整份重寫（重新計算所有 hash）都驗得出來。`/admin/audit` 每次開啟都用鏈上的 `Anchored` 事件核對，hash 鏈斷裂時拒絕上鏈；管理者可按「立即上鏈」。

**伺服器需求**

- 系統要有 `ffmpeg`（或以 `FFMPEG_PATH` 指定），用來解碼臉部影片與音訊。
- 一件案件在 2 核 CPU 上約 15–30 秒，依序在背景處理；`KYC_THREADS` 可調整推論執行緒數。
- 缺少模型或 ffmpeg 時，案件會標示原因並轉人工，不會自動通過。

**開發與測試**

- `NEXT_PUBLIC_KYC_SIMULATE=1`：前端活體步驟改為按鈕模擬完成動作（沒有真人臉部的 E2E 環境）。
- `KYC_PROTOTYPE_AUTO_APPROVE=1`：後台略過模型、全部放行。**兩者都只限開發，正式環境不得開啟。**
- 證件、臉部影像與動作序列存放在 `data/kyc/<身分地址>/<案件>/`（只有浮水印版）；`case.json` 另存 128 維人臉特徵，供恢復時比對本人。
