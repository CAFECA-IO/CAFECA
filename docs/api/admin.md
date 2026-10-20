# 管理後台 API

給 `/admin` 的營運人員使用。

- 驗證：人員以 Passkey 登入後的 session cookie。
- 權限：每個端點另外檢查角色（見各節標題）。沒有登入回 401，角色不符回 403。
- 稽核：所有查詢與決定都寫入稽核紀錄（`data/audit/audit.jsonl`），`who` 是 `姓名（st########）`。

共通規則見 [overview.md](overview.md)。

---

## 人員登入與管理

### `/api/admin/session`

不需登入即可呼叫。

| 方法 | 主體 | 說明 |
|---|---|---|
| `GET` | — | `{ staff, bootstrap }`：目前登入的人員；還沒有任何管理者、且設定了 `KYC_REVIEW_TOKEN` 時 `bootstrap: true` |
| `POST` | `{ action: "challenge" }` | 取得 WebAuthn 登入挑戰 |
| `POST` | `{ action: "login", credentialId, authenticatorData, clientDataJSON, signature }` | 驗證並登入（見下） |
| `POST` | `{ action: "bootstrap", token, name, passkey }` | 建立第一位管理者。需要 `KYC_REVIEW_TOKEN`，之後即關閉 |
| `POST` | `{ action: "logout" }` | 登出 |

`login` 的欄位都是 base64url。伺服器檢查以下各項：

- challenge 是否一次性、是否逾時
- origin、rpId hash
- UP／UV 旗標
- P-256 簽章

重送、竄改或沒有使用者驗證時一律拒絕。`passkey` 的格式是 `{ credentialId, qx, qy }`。

### `/api/admin/staff/join`

不需登入。

| 方法 | 說明 |
|---|---|
| `GET ?code=` | 查看邀請內容（姓名、角色，或「為既有帳號新增 Passkey」） |
| `POST { code, passkey }` | 登記 Passkey 並登入。邀請碼只能用一次，72 小時有效 |

### `/api/admin/staff` — `admin`

| 方法 | 主體 | 說明 |
|---|---|---|
| `GET` | — | `{ me, roles[], staff[] }` |
| `POST` | `{ action: "invite", name, roles[] }` | 邀請新人員，回邀請碼（只顯示一次） |
| `POST` | `{ action: "invite", staffId }` | 為既有人員新增 Passkey 的邀請碼 |
| `POST` | `{ action: "roles", staffId, roles[] }` | 變更角色 |
| `POST` | `{ action: "active", staffId, active }` | 停用或恢復，立即生效 |
| `POST` | `{ action: "removeKey", staffId, credentialId }` | 移除一把 Passkey |

不能停用或降級最後一位管理者，會回 409。

---

## KYC 複核 — `kyc`

| 端點 | 說明 |
|---|---|
| `GET /api/admin/kyc?status=review` | 案件列表，最多 100 筆。`status`：`review`（預設）、`pending`、`processing`、`approved`、`rejected`、`all` |
| `POST /api/admin/kyc` | 核准或退件（見下） |
| `POST /api/admin/kyc` `{ action: "correct", … }` | 更正已核准開戶案件的欄位（見下） |
| `GET /api/admin/kyc/file?account=&case=&kind=front\|back\|face` | 檢視浮水印版證件或臉部影片 |
| `GET /api/admin/kyc/file?account=&case=&kind=ocr` | OCR 原始文字：`{ ocr: { front, back, zoom? } \| null }`。統一編號與長數字已遮罩；`zoom` 是讀不到統一編號時右下角放大重讀的結果 |

每次檢視檔案或 OCR 文字都寫入稽核紀錄。

### 核准或退件

```json
{
  "account": "0x…", "caseId": "…", "decision": "approved | rejected", "note": "…",
  "fields": { "name": "陳大文", "birthday": "1990-01-01", "issueDate": "2019-05-01", "idNumber": "A123456789" }
}
```

- 只能處理 `review` 狀態的案件，否則回 409。核准後立即簽發鏈上證明。
- **核准開戶案件時必須確認欄位**：`fields` 沒填的項目沿用 OCR 擷取值。
  - 姓名與出生日期最後必須有值。
  - OCR 沒擷取到統一編號時，`idNumber` 必填，否則回 400。
  - `idNumber` 要通過檢查碼。伺服器只保存 HMAC，原文不保存、不寫入稽核紀錄。
  - 性別、證件類型、國籍由統一編號推得。
  - 統一編號已綁定其他有效身分時回 409。
- 恢復案件不需要 `fields`。
- 稽核紀錄的 `fieldsConfirmed` 只列出與 OCR 不同的欄位名稱，不記內容。

### 更正已核准的欄位

```json
{ "action": "correct", "account": "0x…", "caseId": "…", "fields": { "name": "陳大雯" }, "note": "OCR 誤讀，依證件更正" }
```

- 只限已核准的開戶案件；`note` 必填；欄位沒有變更回 400。
- 驗證規則同上；更正統一編號時同步更新身分的 HMAC。
- 更正紀錄存在案件的 `corrections`，稽核紀錄為 `kyc.fields.correct`（只記欄位名稱）。
- 之後簽發的 KYC Credential 使用更正後的資料；鏈上證明不需重簽（`claimsRoot` 來自證據雜湊，不含欄位）。

## 法人複核 — `kyc`

| 端點 | 說明 |
|---|---|
| `GET /api/admin/entity?status=review` | 代理人申請的法人驗證列表 |
| `POST /api/admin/entity` | `{ entity, id, decision: "approved" \| "rejected", note }`：退件必須填原因 |
| `GET /api/admin/entity/file?entity=` | 檢視授權書；每次檢視都寫入稽核紀錄 |

`POST /api/admin/entity` 核准前會重新查一次商工登記；狀況不是「核准設立」時回 409。

`POST /api/entity/sync?force=1` 可立即重新監控全部法人，需要 `kyc` 角色，見 [ops.md](ops.md)。

---

## `/api/admin/limits` 交易額度 — `limits`

| 方法 | 參數 | 說明 |
|---|---|---|
| `GET` | （無） | `{ limitAdmin, supported, reasons }`：`supported` 為 `false` 代表部署的是 KeyringValidator v1，不能由管理者調整 |
| `GET` | `?q=@代稱或地址` | `{ account, handle, level, limits, history }`；不是已開戶的身分回 404 |
| `POST` | `{ account, perTx, daily, reason, note }` | 以 `setLimitsFor` 調整 TWDC 額度 → `{ tx, limits }`；v1 回 409 |

POST 參數規則：

- 金額是 TWDC 小數字串，最多 6 位小數。
- `perTx` 不能大於 `daily`。
- `note` 必填（例如申請單號）。

`reason` 原因碼：

| 碼 | 意義 |
|---|---|
| 1 | 使用者申請 |
| 2 | 風控調降 |
| 3 | 實名等級變更 |
| 4 | 法遵要求 |
| 5 | 啟用 BOLT 預設額度 |
| 255 | 其他 |

---

## 依賴方登記 — `admin`

### `GET /api/admin/rp`

依賴方列表。

### `POST /api/admin/rp`

| 主體 | 說明 |
|---|---|
| `{ name, ubn?, domains[], contact, encJwk, dpaVersion, dpaSignedAt }` | 建立依賴方，回傳 API 金鑰（只顯示一次） |
| `{ id, active }` | 停用或恢復 |
| `{ id, dpaVersion, dpaSignedAt }` | 登記或更新資料處理約定 |

建立時的欄位規則：

- `encJwk` 是依賴方的 P-256 加密公鑰，可以是 JWK 物件或 JSON 字串。
- `dpaSignedAt` 不能是未來日期。

沒有 DPA 的依賴方不能使用 `/api/rp/disclosures`。

---

## `/api/admin/disclosures` 資料調閱覆核 — `disclosure`

雙人覆核：第一位核准（可刪減欄位），第二位**不同的人**放行。

| 方法 | 參數 | 說明 |
|---|---|---|
| `GET` | `?status=open` | 列表。`status`：`open`（預設）、`consent`、`review`、`approved1`、`released`、`rejected`、`all` |
| `GET` | `?id=` | 申請內容與將提供的資料預覽；檢視會寫入稽核紀錄 |
| `POST` | `{ id, action: "approve", fields[], note? }` | 第一位核准並決定欄位；第二位再按一次即放行 |
| `POST` | `{ id, action: "reject", reason }` | 退件 |

逾期的申請在列表中以 `dueAt` 標示。

---

## `/api/admin/audit` 稽核紀錄 — `audit` 或 `admin`

| 方法 | 參數 | 說明 |
|---|---|---|
| `GET` | `?action=&subject=&before=&limit=` | `{ chain, anchors, entries[] }`（見下） |
| `POST` | — | 只限 `admin`：立即把（筆數, 最新 hash）寫入 `AuditAnchor` 合約。hash 鏈斷裂時拒絕 |

GET 回應的欄位：

- `chain`：每次查詢都重新驗證整條 hash 鏈的結果。
- `anchors`：用鏈上 `Anchored` 事件核對的結果。
- `limit` 最多 500。

---

## 政策與保存期限 — `admin` 或 `audit`

| 方法 | 說明 |
|---|---|
| `GET /api/admin/maintenance` | `{ policy, terms, pending[] }`：目前的政策數值、條款同意統計、即將被清除的案件（預覽） |
| `POST /api/admin/maintenance` | 只限 `admin`：立即執行每日排程（同意逾期、保存期限清除、稽核上鏈） |
