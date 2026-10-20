# 對外公開 API

給串接 CAFECA 的網站、依賴方（交易所等）與商家使用。共通規則見 [overview.md](overview.md)。

登入（`/dl/auth`）與簽章請求（`/dl/sign`）是使用者在瀏覽器開啟的**頁面**，不是 API。協定、SDK（`/sdk/cafeca-connect.js`）與驗證範例見根目錄 [README](../../README.md)〈Sign in with CAFECA〉第 1–8 節。

---

## `/.well-known/cafeca-configuration`

`GET` · 不需驗證 · CORS 開放 · `cache-control: public, max-age=300`

錢包入口、鏈、合約位址、支援的 claims 與資料調閱的驗章公鑰。SDK 與依賴方應從這裡讀取，不要寫死位址。

```json
{
  "issuer": "https://cafeca.io",
  "protocol": "cafeca-signin",
  "versions": [1],
  "authorization_endpoint": "https://cafeca.io/dl/auth",
  "custom_scheme": "cafeca://auth",
  "sdk": "https://cafeca.io/sdk/cafeca-connect.js",
  "modes": ["popup", "redirect", "post"],
  "channel": {
    "endpoint": "https://cafeca.io/dl/sign",
    "relay": "https://cafeca.io/api/channel",
    "methods": ["sign_message", "sign_typed_data", "send_calls"],
    "max_ttl_seconds": 2592000
  },
  "claims_supported": ["kyc_level", "handle", "legal_name", "doc_type", "nationality", "pairwise_id", "entity_ubn", "entity_name"],
  "max_ttl_seconds": 600,
  "chain": { "id": 8018, "rpc": "https://cafeca.io/api/rpc", "explorer": "https://boltchain.cafeca.io" },
  "contracts": {
    "factory": "0x…", "keyring": "0x…", "attestation": "0x…", "recovery": "0x…",
    "twdc": "0x…", "entryPoint": "0x…", "identityRegistry": "0x…"
  },
  "eip712": { "name": "CAFECA Sign-In", "version": "1", "primaryType": "SignIn", "verifyingContract": "<account>" },
  "kyc_credential": {
    "claims": ["legal_name", "doc_type", "nationality", "pairwise_id", "entity_ubn", "entity_name"],
    "eip712": { "name": "CAFECA KYC Credential", "version": "1", "primaryType": "KycCredential", "verifyingContract": "0x…" },
    "max_ttl_seconds": 600
  },
  "disclosure": {
    "endpoint": "https://cafeca.io/api/rp/disclosures",
    "fields": ["legal_name", "birthday", "sex", "doc_type", "nationality", "issue_date", "kyc_history", "doc_images", "entity"],
    "legal_bases": ["court", "prosecutor", "police", "aml", "consent"],
    "package": { "jwe": { "alg": "ECDH-ES", "enc": "A256GCM" }, "jws": "ES256" },
    "jwks": { "keys": [{ "kty": "EC", "crv": "P-256", "x": "…", "y": "…" }] }
  }
}
```

- 合約尚未部署時，`contracts` 是 `null`。
- `chain.rpc` 可用 `PUBLIC_RPC_URL` 覆寫。
- `disclosure.jwks` 會在 CAFECA 換簽章金鑰（`npm run cutover`）後改變；驗章失敗時請重新抓取。

---

## `/api/rpc`

`POST` · 不需驗證 · CORS 開放

唯讀 JSON-RPC 代理（測試網節點只在內部網路可達）。單筆或批次請求都可以。

只允許以下方法：

- `eth_chainId`、`eth_blockNumber`、`net_version`
- `eth_call`、`eth_estimateGas`、`eth_gasPrice`
- `eth_getBalance`、`eth_getCode`、`eth_getLogs`
- `eth_getTransactionReceipt`、`eth_getTransactionByHash`、`eth_getBlockByNumber`

其他方法（包括 `eth_sendRawTransaction`）回：

```json
{ "jsonrpc": "2.0", "id": 1, "error": { "code": -32601, "message": "method eth_sendRawTransaction not allowed" } }
```

驗證 `SignIn` 簽章時，用這個 RPC 對使用者的身分合約呼叫 `isValidSignature(bytes32,bytes)`，回傳 `0x1626ba7e` 即為有效。

---

## `/api/channel`

`GET`、`POST`、`OPTIONS` · 不需驗證 · CORS 開放

簽章通道的中繼信箱。網站與錢包之間的請求與回應都是**端對端加密**的 `Box`，伺服器讀不到內容。

- 通道 id `ch` 是 128-bit 隨機值（32 位小寫 hex），只有網站與使用者的錢包知道。
- 請求 id `id` 是 16–64 位小寫 hex。
- 資料放在記憶體，10 分鐘後清除；伺服器重啟也會清除。

`Box` 格式：

```json
{ "v": 1, "ch": "<32 hex>", "id": "<16–64 hex>", "iv": "<base64url>", "ct": "<base64url，< 96,000 字元>" }
```

加解密方式（金鑰在登入時協商）見根目錄 README 第 8 節；一般請直接用 SDK 的 `channel.signMessage`／`signTypedData`／`sendCalls`。

### POST

| `op` | 主體 | 誰呼叫 | 說明 |
|---|---|---|---|
| `push` | `{ op, box }` | 網站 | 放入請求。通道已關閉回 410 `channel_closed`；待處理請求過多回 429 `too_many_pending` |
| `reply` | `{ op, box }` | 錢包 | 放入回應，同時移除對應的請求 |
| `close` | `{ op, ch }` | 任一方 | 關閉通道，清除待處理請求；之後的 `push` 一律回 410 |

成功回 `{ "ok": true }`。

### GET

| 參數 | 誰呼叫 | 回應 |
|---|---|---|
| `?ch=a,b,…`（最多 50 個） | 錢包輪詢 | `{ "<ch>": [Box, …], … }`：各通道待處理的請求 |
| `?ch=a&r=<id>` | 錢包讀取單筆 | `{ "box": Box }`；找不到回 404 `not_found` |
| `?ch=a&r=<id>&res=1` | 網站輪詢回應 | 有回應時 `{ "box": Box }`；否則 `{ "pending": true, "closed": false }`；通道已關閉時 `closed: true` |

錢包核准 `send_calls` 時，額度與實體卡規則和使用者自己操作時相同，gas 由平台贊助。超過額度時，錢包會在確認畫面上說明原因：

- 帳戶還沒開啟 BOLT 額度
- 超過單筆上限
- 超過今日剩餘額度

---

## `/api/rp/disclosures`

`GET`、`POST` · `Authorization: Bearer cafeca_rp…` · 伺服器對伺服器

依賴方在洗錢防制調查、司法機關調閱或當事人同意時，申請 CAFECA 保存的實名資料。

使用前：CAFECA 必須在 `/admin/rp` 登記你的網域、P-256 加密公鑰與雙方簽署的資料處理約定（DPA）。加密金鑰對以 `npm run rp -- keygen` 產生，私鑰自己保管。

驗證失敗：

| 狀態 | 原因 |
|---|---|
| 401 | 缺少金鑰或金鑰無效 |
| 403 | 依賴方已停用，或尚未登記 DPA |

### POST：建立申請

```json
{
  "account": "0x…",
  "fields": ["legal_name", "kyc_history", "doc_images"],
  "legalBasis": { "type": "aml", "ref": "文號", "text": "依據說明" },
  "reason": "調閱原因",
  "caseRef": "內部案號（選填）",
  "signIn": { "…": "該帳戶登入你網站時的 SignIn 回應" },
  "pairwiseId": "0x…（與 signIn 二擇一）",
  "deferNoticeUntil": "2027-03-01（選填）",
  "respondBy": "2026-11-15（選填）"
}
```

| 欄位 | 規則 |
|---|---|
| `fields` | 至少一項，可選的值見下表 |
| `legalBasis.type` | `court`、`prosecutor`、`police`、`aml`、`consent` |
| `legalBasis.ref`、`legalBasis.text` | 除 `consent` 外必填 |
| `signIn`／`pairwiseId` | `aml` 與 `consent` 必須二擇一，證明對方是你的客戶。`signIn` 的網域必須是你登記的網域，帳戶必須與 `account` 相同 |
| `deferNoticeUntil` | 只有 `court`／`prosecutor`／`police` 可帶，一年內；暫緩通知當事人 |
| `respondBy` | 只有司法機關可帶，一年內；沒帶則依 CAFECA 政策的工作天數 |
| 法人帳戶 | 不接受 `consent` 類申請 |

`fields` 可選的值：

| 值 | 內容 |
|---|---|
| `legal_name` | 證件姓名 |
| `birthday` | 出生日期 |
| `sex` | 性別 |
| `doc_type` | 證件類型 |
| `nationality` | 國籍 |
| `issue_date` | 證件發證日期 |
| `kyc_history` | 實名驗證歷程（簽發、暫停、撤銷） |
| `doc_images` | 證件影像（浮水印版） |
| `entity` | 法人資料：統編、登記名稱、成員、代簽紀錄 |

成功回 **201** 與申請狀態（格式同 GET `?id=`，`package` 欄位除外）。CAFECA 沒有這個帳戶的實名資料時回 404。

### GET `?id=<id>`：查詢狀態與取得資料包

```json
{
  "id": "…",
  "status": "consent | review | approved1 | released | rejected",
  "account": "0x…",
  "fields": ["legal_name", "kyc_history"],
  "approvedFields": ["legal_name"],
  "legalBasis": { "type": "aml", "ref": "文號" },
  "consent": "pending | granted | denied | expired | null",
  "rejection": null,
  "release": { "at": 1760000000000, "expiresAt": 1760604800000 },
  "dueAt": 1760400000000,
  "consentExpiresAt": null,
  "createdAt": 1759900000000,
  "package": "<compact JWE> | null"
}
```

| `status` | 意義 |
|---|---|
| `consent` | 等待當事人以 Passkey 同意（預設 7 天，逾期視為不同意） |
| `review` | 等待第一位人員核准 |
| `approved1` | 第一位已核准（可能刪減了欄位），等待第二位不同的人員放行 |
| `released` | 已放行，`package` 可下載 |
| `rejected` | 已退件或當事人拒絕，原因在 `rejection` |

`package` 只在 `released` 後 7 天內提供，過期回 410。格式：

- 外層：以你登記的 P-256 公鑰加密的 compact JWE（`alg: ECDH-ES`、`enc: A256GCM`、`kid: <rp id>`、`cty: JWT`）。
- 內層：CAFECA 簽章的 JWS（`ES256`）。驗章公鑰是 `/.well-known/cafeca-configuration` 的 `disclosure.jwks`。
- payload：

  ```json
  {
    "iss": "CAFECA",
    "typ": "cafeca-disclosure+json",
    "id": "…",
    "rp": { "id": "rp…", "name": "…" },
    "account": "0x…",
    "chainId": 8018,
    "legalBasis": { "…": "…" },
    "caseRef": null,
    "fields": ["…"],
    "data": { "…": "…" },
    "releasedAt": "ISO 8601",
    "issuedAt": "ISO 8601"
  }
  ```

每次下載都會寫入稽核紀錄。

參考實作：`CAFECA_RP_KEY=… npm run rp -- fetch <錢包網址> <id> rp-key.json out/`。它會解密、驗章，並把證件影像另存成檔案。

### GET（不帶參數）

回你送出的所有申請：`{ "disclosures": [ … ] }`（每筆格式同上，不含 `package`）。

---

## `/api/tickets/verify`

`GET` · 不需驗證

驗票端掃描票券 QR code 後呼叫，確認發行方簽章與持有人。

| 參數 | 說明 |
|---|---|
| `t` | 票券 id（8–32 位 hex） |
| `h` | 持有人地址 |
| `s` | 發行方簽章 |

有效時回：

```json
{ "valid": true, "ticket": { "title": "…", "subtitle": "…", "venue": "…", "startsAt": 1760000000000, "seat": "…" } }
```

簽章不符或持有人不對時回 `{ "valid": false }`。

---

## `/api/merchant/{item}`

`GET` · x402 風格付費資源（示範商家）

1. 沒有付款憑證時回 **402** 與報價：

   ```json
   {
     "x402Version": 1,
     "error": "payment required",
     "accepts": [{
       "scheme": "exact",
       "network": "boltchain-testnet",
       "asset": "<TWDC 地址>",
       "payTo": "0x…",
       "maxAmountRequired": "<原始單位>",
       "resource": "/api/merchant/<item>",
       "description": "<商品名稱>"
     }]
   }
   ```

2. 付款後，把交易雜湊放在 `X-PAYMENT` header 重送。驗證通過回 `{ "item": "…", "data": … }`。

未知商品回 404。

---

## `/api/index/transfers`

`GET` · 不需驗證 · `no-store`

伺服器索引的 TWDC 轉帳紀錄，新到舊排序。

| 參數 | 說明 |
|---|---|
| `address` | 必填 |
| `limit` | 1–200，預設 50 |
| `before` | 分頁游標：區塊號，結果不含這個區塊 |

```json
{
  "transfers": [
    { "hash": "0x…", "logIndex": 0, "from": "0x…", "to": "0x…", "value": "<原始單位>", "block": 123, "ts": 1760000000 }
  ],
  "lastBlock": 456
}
```

## `/api/index/key-accounts`

`GET ?keyId=<bytes32>` · 不需驗證 · `no-store`

由 Passkey 的 `keyId`（`keccak256(abi.encode(qx, qy))`）找出曾加入這把金鑰的身分，用於登入反查：`{ "accounts": ["0x…"] }`。

結果只是候選清單，錢包仍會以 `KeyringValidator.getKey` 確認金鑰目前有效。
