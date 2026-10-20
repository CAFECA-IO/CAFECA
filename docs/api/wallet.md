# 錢包 API

給 CAFECA 錢包自己的頁面（同源）呼叫。除非另外註明，都需要錢包 session（`cafeca_session` cookie），沒有登入回 401。共通規則見 [overview.md](overview.md)。

第三方網站**不應**直接呼叫這些端點。要取得使用者資料或簽章，請改走登入協定與簽章通道（[public.md](public.md)）。

---

## 登入

錢包以 Passkey 對登入挑戰做 ERC-1271 簽章，伺服器向身分合約驗證後發 session。

### `GET /api/auth/challenge?address=<身分地址>`

不需登入。設定 5 分鐘的 `cafeca_login` cookie，回傳要簽署的雜湊：

```json
{ "hash": "0x…" }
```

```
hash = keccak256(abi.encode("CAFECA_LOGIN", chainId, address, nonce, exp))
```

### `POST /api/auth/verify`

```json
{ "signature": "0x…（ERC-1271 簽章）" }
```

伺服器呼叫 `address.isValidSignature(hash, signature)`，回傳 `0x1626ba7e` 才建立 7 天的 session，並回 `{ "address": "0x…" }`。

| 狀態 | 原因 |
|---|---|
| 400 | 挑戰已過期 |
| 401 | 簽章驗證失敗 |

### `GET /api/auth/me`

不需登入。已登入回 `{ "address": "0x…", "handle": "alice" | null }`，未登入回 `{ "address": null }`。

### `POST /api/auth/logout`

清除 session，回 `{ "ok": true }`。

---

## UserOp 代送

錢包的所有鏈上操作都包成 ERC-4337 UserOperation，由 CAFECA bundler 送出，gas 由 paymaster 依實名等級的每日額度贊助。兩個端點都不需登入：簽章本身就是授權。

### `POST /api/bundler/prepare`

```json
{ "sender": "0x…", "validator": "0x…", "callData": "0x…", "initCode": "0x…（只有第一次建立身分時）" }
```

回 `{ "userOp": { … }, "userOpHash": "0x…" }`。nonce、gas 與 paymaster 資料由伺服器填好；贊助效期依鏈上時間，到當天 UTC 結束為止。錢包對 `userOpHash` 簽章後填入 `userOp.signature`。

拒絕條件：

| 狀態 | 原因 |
|---|---|
| 400 | 地址格式錯誤 |
| 403 | 自行修改交易額度。額度只能由 CAFECA 管理者調整；唯一的例外是 KeyringValidator v1 帳戶把 BOLT 額度從 0 設為平台預設值 |
| 429 | 同一 IP 當天建立的身分已達上限 |

### `POST /api/bundler/send`

```json
{ "userOp": { "…": "已簽章的 UserOp" } }
```

回 `{ "txHash": "0x…", "success": true, "reason": "…（失敗時）" }`。模擬失敗時回 400，錯誤訊息會解讀合約的 revert 原因。

---

## 實名驗證

使用者只提交裝置端即時拍攝、已疊浮水印的證件正反面，以及依隨機動作錄製的臉部影像。伺服器收不到、也不保存原始證件影像。

### `POST /api/kyc/challenge`

不需登入（新裝置恢復身分時也會用到）。回一次性的臉部影像指示：

```json
{ "id": "…", "actions": ["…6 個隨機動作"], "code": "1234", "exp": 1760000000000 }
```

### `POST /api/kyc`

`multipart/form-data`。需先同意最新條款，否則回 **428**。

| 欄位 | 內容 |
|---|---|
| `front`、`back` | 浮水印版證件 JPEG，5 KB–8 MB |
| `face` | 臉部影片（webm／mp4），2 KB–40 MB |
| `challengeId` | `/api/kyc/challenge` 的 `id` |
| `actions` | JSON：每個動作的時間紀錄，順序必須與挑戰一致 |
| `docFeatures` | JSON：裝置端擷取的證件特徵 |

收件後立即回 `pending`，由後台依序驗證：

- 高信心：自動通過，寫入 L2
- 中信心：轉人工複核
- 明確失敗：退件並說明原因

已有審核中的案件、或已通過且仍有效時回 409。

回應（與 GET 相同）：

```json
{
  "caseId": "…",
  "status": "pending | processing | review | approved | rejected",
  "purpose": "onboard",
  "createdAt": 1760000000000,
  "reasons": [],
  "result": null,
  "submitted": { "actions": ["…"] },
  "processedAt": null,
  "reviewedAt": null
}
```

### `GET /api/kyc[?case=<id>]`

查詢指定案件；沒有帶 `case` 時查最新的開戶案件。另外回傳：

- `reverify`：切換正式簽章者後需要重新驗證時才有值，否則是 `null`。
- `guardian`：已通過但平台備援金鑰還沒安裝時，是 `{ address, authoritySig }`，由使用者裝置送出 `setGuardian`；否則是 `null`。

### `GET /api/kyc/file?case=<id>&kind=front|back`

檢視自己送出的浮水印版證件（JPEG）。只能看自己的案件，不提供臉部影片。

### `POST /api/kyc/guardian`

已完成 L2 但備援金鑰沒裝上（例如上次送出失敗）時，重新取得平台授權：`{ "address": "0x…", "authoritySig": "0x…" }`。

| 狀態 | 原因 |
|---|---|
| 403 | 未完成 L2 |
| 409 | 備援金鑰已啟用 |

### `/api/kyc/credential`

只接受錢包頁面自己的請求：檢查 `Sec-Fetch-Site` 與 `Origin`，跨站請求回 403。第三方網站只能透過使用者在登入同意畫面上逐項同意取得。

| 方法 | 參數 | 回應 |
|---|---|---|
| `GET` | `?account=`（選填：自己所屬的法人帳戶） | 可提供的 claims 預覽：`{ active, legal_name, doc_type, nationality, pairwise_id, entity_ubn, entity_name }`（`pairwise_id` 是布林值，表示能否產生） |
| `POST` | `{ audience, nonce, claims[], account? }` | `{ "credential": { "message": …, "signature": "0x…" } \| null }`：KYC 簽章者簽署、綁定 `audience` 與 SignIn `nonce` 的 EIP-712 `KycCredential`，有效 10 分鐘 |

POST 參數規則：

- `audience` 必須是 https origin（本機可用 `http://localhost`）。
- `nonce` 是 8–128 個 `[A-Za-z0-9_-]` 字元。

身分無效或沒有可提供的資料時回 409。

---

## `/api/terms`

| 方法 | 說明 |
|---|---|
| `GET` | `{ version, hash, draft, accepted, acceptedAt, message, history[] }`：`message` 是要以 Passkey 簽署的文字（版本＋內容雜湊＋帳戶） |
| `POST` | `{ version, signature }`：對 `message` 的 ERC-1271 簽章。條款已更新回 409，簽章錯誤回 400 |

---

## `/api/limits/native`

BOLT（原生幣）轉帳額度。新版工廠開戶時就設好平台預設額度（每筆 10、每日 50 BOLT）；這個端點用來補救舊工廠建立、額度為 0 的帳戶。

### `GET`

```json
{
  "perTx": "<wei>",
  "daily": "<wei>",
  "spent": "<wei，近 24 小時>",
  "enabled": true,
  "defaults": { "perTx": "<wei>", "daily": "<wei>" },
  "mode": "admin | self"
}
```

| `mode` | 怎麼啟用 |
|---|---|
| `admin` | KeyringValidator v2：由伺服器代為設定 |
| `self` | v1：帳戶自己送 `setLimits`。有實體卡即時生效，沒有卡片則排程 72 小時後生效 |

### `POST`

只在 `mode: admin` 時可用：由管理者帳戶以 `setLimitsFor` 設定預設額度（原因碼 5），回 `{ "txHash": "0x…" }`。

| 狀態 | 原因 |
|---|---|
| 409 | v1 合約，或額度已設定過 |
| 404 | 帳戶尚未開通 |

---

## `/api/me/disclosures`

我的資料被調閱的紀錄。司法機關要求暫緩通知的案件，到期後才會出現。

### `GET`

```json
{
  "disclosures": [{
    "id": "…",
    "rp": { "name": "…", "ubn": "…", "domains": ["https://…"] },
    "status": "consent | review | approved1 | released | rejected",
    "fields": [{ "key": "legal_name", "label": "證件姓名" }],
    "legalBasis": { "type": "consent", "label": "當事人同意", "ref": "" },
    "reason": "…",
    "createdAt": 1760000000000,
    "releasedAt": null,
    "consent": "pending",
    "consentExpiresAt": 1760600000000,
    "consentMessage": { "approve": "…", "deny": "…" }
  }]
}
```

`consentMessage` 只在等待我同意時提供。

### `POST`

```json
{ "id": "…", "decision": "approve | deny", "signature": "0x…（對對應 consentMessage 的 ERC-1271 簽章）" }
```

同意請求已逾期回 409 或 410。

---

## `/api/profile`

代稱只存在伺服器，不上鏈；用於聊天、轉帳與第三方登入。

| 方法 | 參數 | 登入 | 回應 |
|---|---|---|---|
| `GET` | `?q=@代稱` 或 `?q=0x地址` | 否 | `{ address, handle }`；找不到回 404 |
| `GET` | `?check=代稱` | 是 | `{ handle, valid, available, current, price, treasury, credit }` |
| `POST` | `{ handle, txHash? }` | 是 | `{ handle, changed }` |

規則：

- 代稱是 3–20 個小寫英文、數字或底線，不含 `@`。
- 第一次設定免費；之後變更要先把 `price` TWDC 轉給 `treasury`，再帶 `txHash`。
- 付款會先登記成額度：變更失敗（例如代稱剛好被搶走）時不必重付。
- 換掉的舊代稱保留給原擁有者，其他人不能註冊。

| 狀態 | 原因 |
|---|---|
| 402 | 需要付款 |
| 409 | 代稱已被使用，或付款已用過、不屬於你 |

---

## 聊天

訊息與附件都在瀏覽器端對端加密，伺服器只轉存密文。

| 端點 | 說明 |
|---|---|
| `POST /api/chat/send` | `{ to, fromDevice, kind, envelopes }` → `{ id, ts }`。`kind`：`text`、`pay.request`、`pay.receipt`、`pay.transfer`、`file`、`location`；`envelopes` 是每個收件裝置各一份的密文 |
| `GET /api/chat/inbox?since=<ms>` | `{ messages[], handles{} }`：與我相關、晚於 `since` 的密文訊息，以及對方的代稱 |
| `POST /api/chat/blob?to=<地址>` | 主體是附件密文（application/octet-stream，≤ 10 MB）→ `{ id }`。超過大小回 413 |
| `GET /api/chat/blob?id=<uuid>` | 下載密文；只有傳送者與收件者能下載，其他人回 404 |

---

## 法人帳戶

| 端點 | 說明 |
|---|---|
| `GET /api/entity` | `{ supported, memberValidator, entityFactory, entities[] }`：我所屬的法人帳戶、角色與驗證狀態。合約未部署時 `supported: false` |
| `POST /api/entity` | `{ entity, displayName? }`：登記錢包剛建立的法人帳戶（伺服器在鏈上確認呼叫者是成員）→ `{ entity }` |
| `GET /api/entity/members?entity=` | 只有成員可查：`{ members: [{ member, role, handle }] }`；不是成員回 403 |
| `POST /api/entity/apply` | `multipart`：`entity`、`ubn`、`letter`（非代表人本人時必填：代表人簽署的授權書，PDF／PNG／JPEG，≤ 10 MB）。伺服器查商工登記；代表人本人申請時直接處理，代理人申請轉人工複核 |
| `POST /api/entity/moeaca` | 工商憑證綁定，分兩步（見下） |

`/api/entity/moeaca` 的兩步：

1. `{ entity }` → `{ id, tbs, exp }`：要以工商憑證簽署的內容。
2. `{ id, signature, certb64? }`：PKCS#7 簽章與憑證通過驗證後，立即簽發法人證明。

統一編號格式或檢查碼錯誤回 400；法人合約未部署回 503。

---

## 實體卡

只有完成 L2 實名驗證、且證明有效的身分可以購買或綁定，否則回 403。

| 端點 | 說明 |
|---|---|
| `GET /api/card/order` | `{ price, treasury, orders[] }` |
| `POST /api/card/order` | `{ txHash }`：先以 UserOp 把 `price` TWDC 轉給 `treasury`，再交雜湊核對 → `{ id }` |
| `POST /api/issuer/card` | `{ qx, qy, rpIdHash, replacesKeyId? }`：發卡方對卡片公鑰簽署 card attestation → `{ serialHash, replacesKeyId, issuerSig }` |

`POST /api/card/order` 的錯誤：找不到付款回 402，付款已使用過回 409。

`POST /api/issuer/card`：

- 掛失補發時帶 `replacesKeyId`，舊卡同時汰換。
- 沒有已付款且未使用的訂單時回 402。

---

## 裝置配對與恢復

這三組端點都不需登入。

| 端點 | 說明 |
|---|---|
| `POST /api/link` | 新裝置建立配對：`{ qx, qy, rpIdHash, name }` → `{ id, exp }`（10 分鐘）。只存公鑰與裝置名稱 |
| `GET /api/link?id=` | 新裝置輪詢：`{ status: "waiting", exp }`、`{ status: "linked", address }` 或 `{ status: "expired" }` |
| `POST /api/link/complete` | 既有裝置送出 `addDailyKey` 後回填：`{ id, address }`。伺服器在鏈上確認這把公鑰確實是該身分的裝置金鑰，否則回 409 |
| `POST /api/recovery/guardian` | 裝置全部遺失時的恢復申請（見下） |
| `GET /api/recovery/guardian?account=&case=` | 查詢恢復案件（案件 id 只有送出的裝置知道） |

`POST /api/recovery/guardian` 使用 `multipart`，欄位與 `/api/kyc` 相同，另加 `account`、`qx`、`qy`、`rpIdHash`（新裝置公鑰）。

1. 後台確認與開戶時是同一人。
2. 以平台備援金鑰發起恢復：48 小時後生效，已綁卡的身分為 7 天。
3. 期間主帳戶轉出凍結，舊裝置與卡片都能取消。

以下情況回 403：沒有 L2、證明已撤銷、尚未啟用備援金鑰。

---

## 測試網示範功能

上線前會移除或改為正式實作。

| 端點 | 說明 |
|---|---|
| `POST /api/faucet` | `{ address }` → `{ txHash }`：領 50,000 TWDC，每地址每天一次。不需登入 |
| `GET /api/tickets` | 我的票券，附發行方簽章（用於出示 QR code） |
| `POST /api/tickets/demo` | 發放兩張示範票券（每人最多 6 張） |
| `GET /api/agent/list` | 我的 AI 代理與示範商品目錄 |
| `POST /api/agent/new` | `{ name }` → `{ id, operator, salt }`：產生代理的操作者金鑰（測試網由伺服器代表 TEE 保管） |
| `POST /api/agent/register` | `{ id }` → `{ channel }`：主帳戶在鏈上建立通道後登記給代理 |
| `POST /api/agent/run` | `{ id, item, approvedTx? }`：代理購買商品；金額超過確認門檻時送出 intent，等主人以卡片確認，之後帶 `approvedTx` 取貨 |
| `GET /api/visa/setup` | 發卡處理商資訊 `{ operator, settlement, channel }`（不需登入） |
| `POST /api/visa/register` | `{ channel }`：登記 Visa 支出通道 |
| `POST /api/visa/authorize` | `{ amount, merchant }` → `{ authId, txHash }`：模擬刷卡授權，鎖定金額 7 天 |
| `POST /api/visa/capture` | `{ id, action: "capture" \| "release", amount? }` → `{ txHash }`：清算（可到授權金額的 120%）或釋放 |
| `GET /api/visa/list` | 最近 30 筆授權 |
