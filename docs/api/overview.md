# API 總覽與共通規則

## 網址

| 環境 | 錢包與 API |
|---|---|
| 測試網 | `https://cafeca.io` |
| 本機開發 | `http://localhost:3000`（`npm run dev`） |

所有端點都在同一個網域下，路徑以 `/api/` 開頭；唯一例外是 `/.well-known/cafeca-configuration`（由 `next.config.ts` rewrite 到 `/api/signin/config`）。

對外網址由 `PUBLIC_ORIGIN` 決定；沒有設定時依反向代理的 `X-Forwarded-Host`／`X-Forwarded-Proto` 推算。

## 身分驗證

| 方式 | 用在 | 怎麼帶 |
|---|---|---|
| **錢包 session** | [錢包 API](wallet.md) | `cafeca_session` cookie（HttpOnly、SameSite=Lax、7 天）。以 `/api/auth/challenge` → Passkey 簽章 → `/api/auth/verify` 取得 |
| **人員 session** | [管理後台 API](admin.md) | 管理後台人員以 Passkey（WebAuthn）登入後的 cookie；每個端點另外檢查角色 |
| **依賴方 API 金鑰** | `/api/rp/disclosures` | `Authorization: Bearer cafeca_rp<12 位 hex>_<秘密>`；金鑰在 `/admin/rp` 建立時只顯示一次，伺服器只存 SHA-256 |
| **排程密鑰** | `/api/maintenance` | `x-cafeca-cron: $CRON_SECRET`（常數時間比對；`deploy:server` 自動產生並建立 crontab） |
| 不需驗證 | 公開與可重複呼叫的端點 | — |

人員角色：

| 角色 | 說明 |
|---|---|
| `admin` | 人員與依賴方管理、政策、立即上鏈 |
| `kyc` | KYC 與法人複核 |
| `disclosure` | 資料調閱核准（需兩位不同的人） |
| `limits` | 交易額度 |
| `audit` | 稽核紀錄（唯讀） |

管理者不會自動擁有其他角色。

## 請求與回應

- 請求主體預設是 JSON（`content-type: application/json`）；上傳檔案的端點使用 `multipart/form-data`，會另外註明。
- 金額一律以**字串**表示：TWDC 為小數字串（6 位小數，例如 `"12.5"`），鏈上原始單位（wei）為十進位整數字串。
- 地址可用任何大小寫，回應一律是 checksum 格式。
- 時間：`createdAt`、`dueAt` 這類欄位是 Unix 毫秒；鏈上相關的 `exp`、`validUntil` 是 Unix 秒，會在各端點註明。

## 錯誤格式

除了少數協定端點（見下），錯誤一律回：

```json
{ "error": "人看得懂的中文說明" }
```

| 狀態碼 | 意義 |
|---|---|
| 400 | 參數格式錯誤 |
| 401 | 沒有登入、簽章或 API 金鑰無效 |
| 402 | 需要先付款（找不到付款交易、x402） |
| 403 | 已登入但沒有權限（角色不符、實名等級不足、依賴方停用或缺 DPA） |
| 404 | 找不到資源 |
| 409 | 狀態衝突（已處理過、已使用過、合約版本不支援） |
| 410 | 已過期或通道已關閉 |
| 413 | 檔案過大 |
| 428 | 需先同意最新版服務條款（`/api/terms`） |
| 429 | 超過速率限制 |
| 500 | 伺服器錯誤（細節只寫在伺服器紀錄） |

例外：

- `/api/channel` 的錯誤是代碼：`{ "error": "bad_request" | "not_found" | "channel_closed" | "too_many_pending" }`。
- `/api/rpc` 遵循 JSON-RPC 2.0；不允許的方法回 `{ "error": { "code": -32601 } }`。
- `/api/merchant/[item]` 未付款時回 402 與 x402 報價。

## CORS

只有給第三方網站直接從瀏覽器呼叫的端點開放 `access-control-allow-origin: *`：

- `/.well-known/cafeca-configuration`
- `/api/rpc`
- `/api/channel`
- `/sdk/*`

其他端點只供同源的錢包頁面或伺服器對伺服器使用。`/api/kyc/credential` 另外檢查 `Sec-Fetch-Site` 與 `Origin`，拒絕任何跨站請求。

## 速率限制

| 對象 | 上限 | 設定 |
|---|---|---|
| 建立新身分（`/api/bundler/prepare` 帶 `initCode`） | 每個 IP 每天 10 個 | `MAX_IDENTITIES_PER_IP_PER_DAY` |
| 新裝置配對（`/api/link`） | 每個 IP 每天 50 次 | — |
| 測試幣（`/api/faucet`） | 每個地址每天 1 次 | 合約限制 |
| 簽章通道待處理請求 | 每個通道 5 筆 | `MAX_PENDING`（`lib/channel.ts`） |
| Gas 贊助 | 依實名等級的每日額度 | paymaster tier |

## 端點總表

| 端點 | 方法 | 驗證 | 文件 |
|---|---|---|---|
| `/.well-known/cafeca-configuration` | GET | — | [public](public.md#well-knowncafeca-configuration) |
| `/api/rpc` | POST | — | [public](public.md#apirpc) |
| `/api/channel` | GET、POST | — | [public](public.md#apichannel) |
| `/api/rp/disclosures` | GET、POST | 依賴方金鑰 | [public](public.md#apirpdisclosures) |
| `/api/tickets/verify` | GET | — | [public](public.md#apiticketsverify) |
| `/api/merchant/{item}` | GET | x402 | [public](public.md#apimerchantitem) |
| `/api/index/transfers` | GET | — | [public](public.md#apiindextransfers) |
| `/api/index/key-accounts` | GET | — | [public](public.md#apiindexkey-accounts) |
| `/api/profile` | GET、POST | 部分需登入 | [wallet](wallet.md#apiprofile) |
| `/api/auth/challenge`、`/verify`、`/me`、`/logout` | GET／POST | — | [wallet](wallet.md#登入) |
| `/api/bundler/prepare`、`/send` | POST | — | [wallet](wallet.md#userop-代送) |
| `/api/kyc`、`/challenge`、`/file`、`/guardian`、`/credential` | GET／POST | 多數需登入 | [wallet](wallet.md#實名驗證) |
| `/api/terms` | GET、POST | 登入 | [wallet](wallet.md#apiterms) |
| `/api/limits/native` | GET、POST | 登入 | [wallet](wallet.md#apilimitsnative) |
| `/api/me/disclosures` | GET、POST | 登入 | [wallet](wallet.md#apimedisclosures) |
| `/api/chat/*` | GET、POST | 登入 | [wallet](wallet.md#聊天) |
| `/api/entity*` | GET、POST | 登入 | [wallet](wallet.md#法人帳戶) |
| `/api/card/order`、`/api/issuer/card` | GET、POST | 登入 | [wallet](wallet.md#實體卡) |
| `/api/link`、`/api/link/complete`、`/api/recovery/guardian` | GET、POST | — | [wallet](wallet.md#裝置配對與恢復) |
| `/api/faucet`、`/api/tickets*`、`/api/agent/*`、`/api/visa/*` | — | — | [wallet](wallet.md#測試網示範功能) |
| `/api/admin/*` | — | 人員 | [admin](admin.md) |
| `/api/maintenance`、`/api/identity/sync`、`/api/entity/sync`、`/api/index/status` | — | — | [ops](ops.md) |
