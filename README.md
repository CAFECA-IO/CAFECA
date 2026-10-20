# CAFECA 數位身分錢包

以 Boltchain 為基礎的數位身分證與錢包：在裝置上建立的 FIDO2 金鑰就是身分根（不需要任何第三方帳號），ERC-4337＋ERC-7579 模組化帳戶，以 Passkey 與 CAFECA 卡（指紋＋螢幕）操作，整合端對端加密聊天、支付、AI 子錢包與 Payment Protocol 支出通道，並讓任何網站免註冊使用「Sign in with CAFECA」。

| 目錄 | 內容 |
| --- | --- |
| [`contracts/`](contracts) | Solidity 合約（Foundry）：帳戶、工廠、Keyring／Recovery／Channel 模組、Paymaster、登記合約 |
| [`app/`](app) | Next.js 16 原型：錢包、卡片、AI 代理、聊天、安全與恢復，部署於 Boltchain 測試網 |
| [`docs/`](docs) | 文件：[API 說明](docs/README.md)（對外公開、錢包、管理後台、排程與維運） |

快速開始請見各目錄的 README。

---

## Sign in with CAFECA：第三方網站登入串接

任何網站都可以讓使用者以 CAFECA 身分登入，**不需要向 CAFECA 註冊、申請 client ID 或 API key**，也不需要 CAFECA 伺服器參與驗證。

### 原理

1. 你的後端產生一次性 `nonce`，前端把「登入請求」交給 CAFECA 錢包（彈出視窗、整頁導向或 QR code）。
2. 錢包顯示你的**網域**，使用者確認後以 Passkey 簽署一則 EIP-712 `SignIn` 訊息。訊息內含你的網域、nonce、有效時間與使用者同意提供的資料。
3. 錢包只把結果送回同一個網域：popup 用 `postMessage` 並指定 targetOrigin，另外兩種方式則要求 `redirectUri`／`responseUri` 必須與網域同源。
4. 你的後端用公開 RPC 呼叫使用者身分合約的 `isValidSignature`（ERC-1271）。回傳 `0x1626ba7e` 就代表這個人確實控制該 CAFECA 身分。

使用者的**身分合約地址（`account`）就是他在你網站上的唯一 ID**，換裝置、換 Passkey、以實體卡或備援金鑰恢復之後都不會變。

仿冒網站拿到的簽章綁定的是仿冒網站自己的網域，拿到你的網站用會驗證失敗。

### 1. 前端（彈出視窗）

```html
<script src="https://<CAFECA 錢包網域>/sdk/cafeca-connect.js"></script>
<button id="login">以 CAFECA 登入</button>
<script>
  const cafeca = CafecaConnect.create({ wallet: "https://<CAFECA 錢包網域>" });

  document.getElementById("login").onclick = async () => {
    // signIn 必須在點擊事件中呼叫，否則彈出視窗會被瀏覽器擋下；nonce 可以傳入非同步函式
    const response = await cafeca.signIn({
      nonce: () => fetch("/api/cafeca/nonce", { method: "POST" }).then((r) => r.json()).then((j) => j.nonce),
      statement: "登入 Example Shop",          // 選填，顯示給使用者看，最多 200 字
      claims: ["kyc_level", "handle"],          // 選填，使用者可以逐項取消；姓名等實名資料見第 9 節
    });
    // 把 response 原封不動交給後端驗證（前端拿到的結果不可信任）
    await fetch("/api/cafeca/login", { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify(response) });
  };
</script>
```

`signIn` 失敗時會拋出 `CafecaError`，`code` 為以下其中之一：

- `access_denied`：使用者拒絕
- `closed`：使用者關閉視窗
- `popup_blocked`：瀏覽器擋下彈出視窗
- `timeout`：逾時
- `invalid_nonce`：nonce 格式錯誤

### 2. 後端驗證（Node.js）

複製 [`app/sdk/cafeca-verify.ts`](app/sdk/cafeca-verify.ts) 和 [`app/src/lib/signin.ts`](app/src/lib/signin.ts)，只需要 `viem` 這個依賴。

```ts
import { createCafecaVerifier, newNonce } from "./cafeca-verify";

const cafeca = createCafecaVerifier({ wallet: "https://<CAFECA 錢包網域>" });
const DOMAIN = "https://shop.example"; // 你的網站 origin，要與瀏覽器網址列完全相同

app.post("/api/cafeca/nonce", (req, res) => {
  const nonce = newNonce();
  req.session.cafecaNonce = { nonce, exp: Date.now() + 5 * 60_000 }; // 綁定目前的瀏覽器 session
  res.json({ nonce });
});

app.post("/api/cafeca/login", async (req, res) => {
  const saved = req.session.cafecaNonce;
  delete req.session.cafecaNonce; // 不論成功與否都作廢：一個 nonce 只能用一次
  if (!saved || saved.exp < Date.now()) return res.status(400).json({ error: "nonce 已過期" });
  try {
    const user = await cafeca.verify(req.body, { domain: DOMAIN, nonce: saved.nonce });
    // user.account：身分合約地址（唯一 ID）
    // user.claims.kyc_level：鏈上有效實名等級（0 未實名、2 已通過證件＋臉部驗證；撤銷、暫停、過期都是 0）
    // user.claims.kyc：IdentityRegistry v2 的完整狀態（主體類型、狀態、簽章者等級…，見第 9 節）
    // user.claims.handle：CAFECA 代稱（由錢包查詢確認；handleVerified=false 時只能拿來顯示）
    // user.claims.legal_name／doc_type／nationality／pairwise_id：要求時才有，來自 KYC Credential（第 9 節），已驗證簽章
    // user.recoveryPending：身分正在恢復中，建議暫停敏感操作
    req.session.userId = user.account;
    res.json(user);
  } catch (e) {
    res.status(401).json({ error: (e as Error).message });
  }
});
```

`createCafecaVerifier` 第一次呼叫時會讀取 `https://<錢包網域>/.well-known/cafeca-configuration`，取得 chainId、RPC 與合約位址。

- 如果不想依賴這個設定檔，可以用 `config` 參數把設定寫死在程式裡。
- `rpcUrl` 可以改用你自己的節點。
- 設定 `resolveHandle: false`，就不會向錢包查詢代稱。

### 3. 其他回傳方式

| 方式 | 適用情境 | 呼叫 |
| --- | --- | --- |
| `popup` | 桌機、一般瀏覽器（預設） | `cafeca.signIn({...})` |
| `redirect` | 行動裝置、擋彈出視窗的環境（in-app browser） | `cafeca.redirect({ nonce, redirectUri })`。回到 `redirectUri` 頁面後呼叫 `CafecaConnect.handleRedirect()`，回傳 `{ response }`、`{ error }` 或 `null` |
| `post` | 跨裝置：電腦顯示 QR code，用手機上的 CAFECA 掃描 | `await cafeca.authLink({ nonce, mode: "post", responseUri: "/api/cafeca/callback" })`，把連結做成 QR code |

- **`redirect`**：結果放在網址的 `#cafeca=`（fragment 不會送到任何伺服器），`handleRedirect()` 讀取後會清除網址列。
- **`post`**：手機上的錢包以 `POST text/plain`（`no-cors`、不帶 cookie）把回應送到 `responseUri`。你的後端驗證後，把結果掛在該 nonce 上；電腦頁面再以 nonce 輪詢自己的後端，確認 nonce 屬於這個瀏覽器的 session 後才完成登入。

### 4. 協定細節（非 Node 環境自行實作）

**登入請求**：以 base64url(JSON) 放在 `https://<錢包網域>/dl/auth?v=1&req=<…>`。原生 App 可改用 `cafeca://auth?v=1&req=<…>`。

| 欄位 | 必填 | 說明 |
| --- | --- | --- |
| `v` | ✓ | `1` |
| `domain` | ✓ | 你的網站 origin（`https://…`，本機開發可用 `http://localhost`） |
| `uri` | ✓ | 發起登入的頁面，必須與 `domain` 同源 |
| `nonce` | ✓ | 8–128 字元的 `[A-Za-z0-9_-]` |
| `issuedAt` / `expiresAt` | ✓ | Unix 秒；有效時間最長 600 秒 |
| `mode` | ✓ | `popup` / `redirect` / `post` |
| `redirectUri` | redirect | 與 `domain` 同源 |
| `responseUri` | post | 與 `domain` 同源 |
| `statement` |  | 最多 200 字 |
| `claims` |  | `kyc_level`、`handle`、`legal_name`、`doc_type`、`nationality`、`pairwise_id`、`entity_ubn`、`entity_name`（後六項見第 9 節） |
| `state` |  | 原樣帶回 |
| `channel` |  | `{ "pub": "<P-256 公鑰 base64url>", "ttl": 秒 }`：要求開啟簽章通道（見第 8 節），`ttl` 最長 30 天 |

錢包遇到任何不合規的欄位都會拒絕簽署。

**登入回應**：

```json
{
  "v": 1, "type": "cafeca:auth",
  "account": "0x…身分合約",
  "chainId": 8018,
  "message": { "domain": "…", "uri": "…", "nonce": "…", "issuedAt": 0, "expiresAt": 0, "statement": "…", "claims": "handle,kyc_level", "channel": "" },
  "signature": "0x…",
  "claims": { "handle": "…" },
  "state": "…",
  "channel": { "id": "…", "walletPub": "…", "expiresAt": 0 },
  "credential": { "message": { "account": "0x…", "audience": "…", "nonce": "…", "…": "…" }, "signature": "0x…" }
}
```

`message.claims` 是使用者實際同意提供的項目，排序後以逗號分隔。

`message.channel` 是 `<通道 id>.<網站公鑰>.<錢包公鑰>.<到期 Unix 秒>`，使用者沒有開啟簽章通道時為空字串；通道因此和這次登入由同一個簽章背書。

拒絕時的回應為 `{ "v": 1, "type": "cafeca:auth", "error": "access_denied", "nonce": "…", "state": "…" }`。

**簽署內容（EIP-712）**：

```
domain  = { name: "CAFECA Sign-In", version: "1", chainId, verifyingContract: account }
SignIn  = (string domain, string uri, string nonce, uint256 issuedAt, uint256 expiresAt, string statement, string claims, string channel)
```

**驗證步驟**：

1. 確認 `message.domain` 與你的 origin **完全相同**，`message.nonce` 是你發出且未使用過的，`chainId` 正確，現在時間早於 `expiresAt`。
2. 計算 `hash = hashTypedData(domain, SignIn, message)`。
3. 以 `eth_call` 呼叫 `account.isValidSignature(hash, signature)`，結果必須等於 `0x1626ba7e`。
4. 若 `claims` 含 `kyc_level`：呼叫 `identityRegistry.statusOf(account)`（IdentityRegistry v2，見第 9 節），以 `effectiveLevel` 為等級；正式實名還要求 `signerClass == PRODUCTION`。舊部署沒有 v2 時才讀 `attestation.levelOf(account)`。
5. 若含 `handle`：呼叫 `GET https://<錢包網域>/api/profile?q=<account>` 取得代稱。代稱存在 CAFECA 伺服器，不上鏈；回應裡自稱的 `claims.handle` 不可信任。代稱第一次設定後固定，但使用者付費後可以變更（舊代稱保留、不會轉給別人），所以帳戶主鍵請用 `account`，不要用代稱。
6. 可選：呼叫 `recovery.isPending(account)`，檢查身分是否正在恢復中。
7. 若 `message.channel` 不是空字串：確認其中的網站公鑰是你自己產生的（`verify(…, { channelPub })`），到期時間不超過登入時間加 30 天。
8. 若 `claims` 含 `legal_name`、`doc_type`、`nationality`、`pairwise_id` 其中之一：依第 9 節驗證 `credential`。使用者同意但錢包沒有資料時，回應裡不會有對應欄位。

合約位址見 `/.well-known/cafeca-configuration` 的 `contracts`。

### 5. CAFECA 簽章編碼規格

CAFECA 身分是智能合約帳戶，簽章由使用者的 FIDO2 金鑰（Passkey 或實體卡）以 **WebAuthn ES256（P-256）** 產生，再包成帳戶合約看得懂的格式。

**建議一律呼叫 `account.isValidSignature(hash, signature)` 驗證，不要自行解析。** 原因有兩個：

- 金鑰會新增、移除、輪替，只有合約知道目前哪些有效。
- 上線前會加上 ERC-7739 包裝（見第 7 節），格式會改變，但 `isValidSignature` 的呼叫方式不變。

以下規格給需要除錯、稽核，或在沒有 EVM 函式庫的環境實作的人。

#### 5.1 各情境簽署的 hash

| 情境 | 被簽的 32-byte `hash` | 簽章格式 |
| --- | --- | --- |
| 登入 | `hashTypedData`（`CAFECA Sign-In`，見第 4 節） | ERC-1271 |
| 簽章通道 `signMessage` | `hashMessage(message)`（EIP-191：`"\x19Ethereum Signed Message:\n" + len + message` 再 keccak256，len 為 UTF-8 位元組數的十進位字串） | ERC-1271 |
| 簽章通道 `signTypedData` | `hashTypedData(typedData)`（EIP-712） | ERC-1271 |
| 鏈上操作（UserOperation） | EntryPoint v0.8 的 `userOpHash` | `UserOp.signature` |

#### 5.2 ERC-1271 簽章版面

```
signature      = validator (20 bytes) ‖ abi.encode(SignatureData)

SignatureData  = (bytes32 keyId, WebAuthnSig sig)
WebAuthnSig    = (bytes   authenticatorData,
                  string  clientDataJSON,
                  uint256 challengeIndex,
                  uint256 typeIndex,
                  bytes32 r,
                  bytes32 s)
```

帳戶合約取前 20 bytes 當作 validator 位址，確認是已安裝的模組後，把其餘 bytes 交給該模組的 `isValidSignatureWithSender`。

| 欄位 | 說明 |
| --- | --- |
| `validator` | 裝置 Passkey 與實體卡的簽章一律是 **KeyringValidator**，位址見 `/.well-known/cafeca-configuration` 的 `contracts.keyring` |
| `keyId` | `keccak256(abi.encode(qx, qy))`，即 P-256 公鑰座標的雜湊；公鑰可用 `keyring.getKey(account, keyId)` 查詢 |
| `authenticatorData` | 瀏覽器回傳的原始 bytes：`rpIdHash (32) ‖ flags (1) ‖ signCount (4) ‖ [擴充]`。flags 必須有 UP（0x01）與 UV（0x04），不可有 AT（0x40） |
| `clientDataJSON` | 瀏覽器回傳的原始 UTF-8 JSON 字串，**不可重新排版或重新序列化** |
| `challengeIndex` | `"challenge":"` 在 `clientDataJSON` 中的起始 byte 位置 |
| `typeIndex` | `"type":"webauthn.get"` 在 `clientDataJSON` 中的起始 byte 位置 |
| `r`, `s` | P-256 簽章，**`s` 必須 ≤ n/2**（low-s，防止簽章延展），錢包會自動正規化 |

實際的 abi.encode 版面（位移從第 21 個 byte 起算；登入簽章總長約 600 bytes）：

```
0x000  0x20                      → SignatureData 起點
0x020  keyId
0x040  0x40                      → sig 相對 SignatureData 的位移（sig 起點 0x060）
0x060  0xc0                      → authenticatorData 位移（起點 0x120）
0x080  0x120                     → clientDataJSON 位移（起點 0x180）
0x0a0  challengeIndex            例：0x17（23）
0x0c0  typeIndex                 例：0x01
0x0e0  r
0x100  s
0x120  authenticatorData 長度     例：0x25（37）
0x140  authenticatorData（補齊 32 的倍數）
0x180  clientDataJSON 長度        例：0x86（134）
0x1a0  clientDataJSON（補齊 32 的倍數）
```

#### 5.3 KeyringValidator 的驗證規則

1. `keyId` 必須是這個帳戶目前有效的金鑰（裝置金鑰 DAILY 或實體卡 MASTER 皆可）。
2. `authenticatorData` 前 32 bytes 必須等於該金鑰登記時的 `rpIdHash`，也就是 `sha256(CAFECA 錢包的 RP ID)`，RP ID 為錢包網域的主機名稱。
3. flags 必須有 UP 與 UV（使用者在場並通過指紋／PIN），不可有 AT。
4. `clientDataJSON` 在 `typeIndex` 處必須是 `"type":"webauthn.get"`。
5. `clientDataJSON` 在 `challengeIndex` 處必須是 `"challenge":"<base64url(hash)>"`，其中 base64url 不補 `=`，編碼的是 32-byte hash 的原始 bytes。
6. `s ≤ n/2`。
7. 以 `sha256(authenticatorData ‖ sha256(clientDataJSON))` 為訊息，用金鑰的 `(qx, qy)` 做 P-256 驗證。鏈上優先使用 EIP-7951 precompile（0x100），沒有時退回 Solidity 實作。

驗證時綁定的是 `rpIdHash`，合約不檢查 `clientDataJSON` 裡的 `origin`。

交易額度（單筆與每日上限）只能由 CAFECA 管理者調整（KeyringValidator v2 的 `setLimitsFor`，發出 `LimitsSetByAdmin` 事件），使用者的裝置金鑰與實體卡都不能修改；透過簽章通道送出的 `sendCalls` 也一樣。

#### 5.4 其他簽章格式

| 對象 | 格式 |
| --- | --- |
| UserOperation（KeyringValidator） | `UserOp.signature = abi.encode(SignatureData)`，**沒有** 20-byte 前綴。validator 由 `nonce` 的最高 160 bits 指定（`nonce = validator << 96 ‖ 序號`），挑戰值是 `userOpHash` |
| 實體卡（MASTER）的 UserOp | 同上，另外 flags 不可有 BE（0x08，可同步的金鑰不能當卡片）。操作需要卡片確認時，`authenticatorData` 必須是 77 bytes：37 bytes 之後接卡片擴充 CBOR `{ "ctxd": bstr(32) }`（`A1 64 63747864 58 20` ‖ 32 bytes），flags 帶 ED（0x80）。`ctxd = sha256(abi.encode(TxSummary[]))` 是卡片螢幕顯示內容的雜湊，必須等於鏈上 `previewAssessment` 算出的值（所見即所簽，規格 §9.2） |
| AI 子錢包／支出通道帳戶（ChannelValidator） | ERC-1271：`validator (20) ‖ r (32) ‖ s (32) ‖ v (1)`，由通道操作者以 secp256k1 直接對 `hash` 簽署（不加 EIP-191 前綴）；通道撤銷後失效 |
| 平台備援金鑰（RecoveryValidator） | 不能產生一般簽章，`isValidSignature` 一律回傳無效 |

#### 5.5 解析範例（viem）

```ts
import { decodeAbiParameters, slice, type Hex } from "viem";

const SIGNATURE_DATA = [{
  type: "tuple",
  components: [
    { name: "keyId", type: "bytes32" },
    { name: "sig", type: "tuple", components: [
      { name: "authenticatorData", type: "bytes" },
      { name: "clientDataJSON", type: "string" },
      { name: "challengeIndex", type: "uint256" },
      { name: "typeIndex", type: "uint256" },
      { name: "r", type: "bytes32" },
      { name: "s", type: "bytes32" },
    ] },
  ],
}] as const;

export function decodeCafecaSignature(signature: Hex) {
  const validator = slice(signature, 0, 20);
  const [data] = decodeAbiParameters(SIGNATURE_DATA, slice(signature, 20));
  return { validator, keyId: data.keyId, ...data.sig };
}
```

錢包端的編碼實作見 [`app/src/lib/userop.ts`](app/src/lib/userop.ts)（`encode1271`、`encodeKeyringSignature`）與 [`app/src/lib/webauthn.ts`](app/src/lib/webauthn.ts)。合約端的驗證見 [`contracts/src/lib/WebAuthnLib.sol`](contracts/src/lib/WebAuthnLib.sol) 與 `KeyringValidator.isValidSignatureWithSender`。

### 6. 網站資訊（選填）

在 `https://<你的網域>/.well-known/cafeca-site.json` 放上以下內容，並加上 `Access-Control-Allow-Origin: *`：

```json
{ "name": "Example Shop", "icon": "/icon.png" }
```

- 錢包會把名稱標示為「網站自稱」，**畫面永遠以網域為主**。
- 圖示只接受你網域上的檔案。
- 沒有這個檔案也可以正常登入。

### 7. 安全注意事項

- **一定要在後端驗證**：SDK 不驗證簽章，前端拿到的回應可以被竄改。
- **nonce 必須綁定瀏覽器 session、只能使用一次，並在驗證前就作廢**，以防重送攻擊。
- **以 `account` 作為使用者 ID**，不要用代稱：代稱可以更換，也可能被其他人使用。
- **網域比對必須完全相同**（含 scheme 與 port），不要用 `endsWith` 或只比對主機名稱。
- **跨裝置 QR 有被轉送的風險**：攻擊者可能把你網站的登入 QR 放到自己的頁面上，誘騙使用者掃描（QRLjacking）。
  - 錢包會提醒使用者確認「是自己剛打開的頁面」。
  - 敏感網站建議 QR 有效時間設短（例如 2 分鐘），在電腦畫面同時顯示登入裝置與位置，或者只提供 popup／redirect。
- **AI 子錢包**是獨立地址，也能產生有效簽章。如果只接受本人登入，可以要求 `kyc_level ≥ 2`（AI 子錢包不會有實名等級）。
- **登入簽章不能拿去做其他事**：登入畫面只會簽署錢包自己組出的 `SignIn` 結構。網站要簽其他內容必須走簽章通道，而通道會拒絕 `CAFECA Sign-In`、UserOperation 與以 CAFECA 合約為對象的結構，Permit 等授權也會顯示紅色警示。
- **TODO：合約層的 ERC-7739 防重放封裝尚未實作。** 目前「登入簽章無法挪用到其他用途」是靠錢包端限制來保證，上線前會補上合約層保護。
- **登入後的 session 由你的網站自行管理。** CAFECA 不發 access token，也無法替使用者撤銷你網站的 session；使用者在 CAFECA 的「安全 → 以 CAFECA 登入的網站」只看得到本機紀錄。

### 8. 簽章通道：登入後請使用者簽署或付款

登入時加上 `channel: true`，使用者同意後，網站之後可以透過通道請使用者：

- 簽署文字訊息（`signMessage`）
- 簽署 EIP-712 結構（`signTypedData`）
- 執行鏈上操作（`sendCalls`）：例如付款，gas 由平台贊助

通道**不是授權**：每一筆都會在 CAFECA 錢包顯示你提供的說明，以及錢包自己解析的實際內容，由使用者確認後才簽署。網站無法在使用者不知情的情況下簽出任何東西。

```js
// 登入時要求開啟通道
const response = await cafeca.signIn({ nonce: getNonce, channel: true }); // 或 { ttl: 7 * 86400 }
await fetch("/api/cafeca/login", { method: "POST", body: JSON.stringify(response) });
const ch = await cafeca.channel(response);      // 使用者沒有同意開啟時為 null
localStorage.setItem("cafeca.channel", ch.id);   // 之後以 cafeca.restoreChannel(id) 取回

// 每一筆都必須附上說明（description），沒有說明的請求錢包會直接拒絕
const { signature } = await ch.signMessage("我同意會員條款 v3", { title: "同意會員條款", detail: "不會產生任何費用" });

const { txHash, success } = await ch.sendCalls(
  [{ to: TWDC, data: transferCalldata }],
  { title: "付款 12 TWDC", detail: "訂單 A1024：耶加雪菲 200g" },
  { transport: "relay", onPending: ({ link }) => showQr(link) }, // 跨裝置：送到使用者手機上的 CAFECA
);
```

| 項目 | 說明 |
| --- | --- |
| `description` | **必填**：`title`（≤ 60 字）＋ `detail`（≤ 500 字，選填）。錢包標示為「網站說明」，並在下方列出錢包自己解析的實際內容供使用者核對，所以請寫得和實際內容一致 |
| `transport` | `popup`（預設，同一台裝置，必須在點擊事件中呼叫）或 `relay`（CAFECA 中繼信箱，使用者在手機開啟 CAFECA 時會看到提示；`onPending` 會拿到可做成 QR 的連結） |
| 回傳 | `signMessage`／`signTypedData` → `{ signature }`；`sendCalls` → `{ txHash, success }` |
| 錯誤 `code` | `rejected`（使用者拒絕）、`invalid_request`（缺少說明、內容不合規或被防護封鎖）、`channel_closed`（使用者已關閉或過期）、`closed`、`timeout`、`popup_blocked` |

後端驗證通道簽章：

```ts
const ok = await cafeca.verifyMessage({ account: session.userId, message, signature });
const ok2 = await cafeca.verifyTypedData({ account: session.userId, typedData, signature });
```

EIP-712 的數值請使用 `number` 或十進位字串，不要傳 `bigint`（要經過 JSON）。

**錢包端防護**（網站無法關閉）：

- 拒絕 EIP-712 網域為 `CAFECA Sign-In`、`ERC4337`，或 `verifyingContract` 為使用者帳戶、EntryPoint、CAFECA 系統合約的訊息，避免借通道偽造登入或帳戶操作。
- `sendCalls` 不可呼叫使用者帳戶本身與 CAFECA 模組（金鑰、恢復、支出通道、裝置目錄）。錢包只接受鏈上解析為轉帳、授權或一般合約呼叫的操作；額度與實體卡確認規則和使用者自己操作時相同。
- 授權（Permit、approve）、無法解讀的合約呼叫、轉出 BOLT 會顯示紅色警示。
- 每個請求 id 只處理一次，有效時間最長 10 分鐘；中繼信箱每個通道最多 5 筆待處理。

**加密與中繼**：請求與回應都以 ECDH(網站金鑰, 錢包金鑰) → HKDF-SHA256 → AES-256-GCM 加密。

- 網站端私鑰由 SDK 以不可匯出的 `CryptoKey` 存在 IndexedDB。
- 中繼（`/api/channel`）只看得到密文、通道 id 與時間。
- 使用者可以在 CAFECA「安全 → 以 CAFECA 登入的網站」關閉通道，之後的請求會收到 `channel_closed`。

需要**不經使用者逐筆確認**的定期扣款或 AI 代付，請改用支出通道（規格 §6）：在鏈上預先設定額度，由代理人自行簽署。

### 9. 實名等級、撤銷與事件（IdentityRegistry v2）

依賴方（例如交易所）要把 CAFECA 的實名結果用在自己的業務上時，一律讀 **IdentityRegistry v2**。位址見 `/.well-known/cafeca-configuration` 的 `contracts.identityRegistry`。

> **目前所有 L2 都是原型簽章。** 簽章者等級為 `PROTOTYPE`。自建的後台驗證（OCR、活體重檢、語音、人臉比對）已經接上，目前一律經人工複核才核准；門檻以真實樣本校準、正式 kycSigner 放進 HSM 之後，才會換成 `PRODUCTION` 簽章者並移除原型簽章者，原型期的 L2 屆時一律降為 0，需要重新驗證。

**等級語意**

| 等級 | 意義 |
| --- | --- |
| L0 | 未實名；或證明已過期、已撤銷、已暫停、簽章者已失效 |
| L1 | 手機驗證。**不是實名**，依賴方不應視為已確認身分 |
| L2 | 自然人：身分證正反面＋6 動作活體影像，後台比對本人（原型期見上方說明） |

- 效期一年，過期自動視為 L0。
- `subjectType`：0 自然人、1 法人。**自然人的 L2 不等於法人**，法人證明由商工登記驗證後另行簽發（見下方「法人帳戶」）。

**讀取**

```ts
const s = await cafeca.identityStatus(account); // app/sdk/cafeca-verify.ts
// { subjectType: "person", level: 2, effectiveLevel: 2, status: "active", expiry, jurisdiction: "TW",
//   nonce: "1", signer: "0x…", signerClass: "prototype" }
const isVerifiedPerson = s?.subjectType === "person" && s.effectiveLevel === 2 && s.signerClass === "production";
```

合約介面：`statusOf(account)`、`levelOf(account)`（有效等級，含原型）、`productionLevelOf(account)`（只計入正式簽章者）、`nonceOf(account)`。

**事件格式**（固定；依賴方可以鏡像進自己的帳本，查核時直接以鏈上 log 重播）

```
Attested(address indexed account, uint8 subjectType, uint8 level, uint48 expiry, bytes32 claimsRoot, bytes2 jurisdiction, address signer, uint64 nonce)
Suspended(address indexed account, uint8 reason, address by, uint64 nonce)
Revoked(address indexed account, uint8 reason, address by, uint64 nonce)
SignerSet(address indexed signer, uint8 signerClass)   // 0 NONE、1 PROTOTYPE、2 PRODUCTION
```

- 每個帳戶的 `nonce` 從 1 起遞增，`Attested`／`Suspended`／`Revoked` 共用同一個序列。依賴方只要保留最大 nonce 的那筆事件，就是目前狀態。
- 新的 `Attested` 會覆蓋之前的暫停或撤銷（例如使用者重新驗證通過）。
- 簽章者被移除（`SignerSet(..., 0)`）時，該簽章者簽發的證明全部失效，不會個別發出 `Revoked`；鏡像時請一併處理 `SignerSet`。

**原因碼**：1 使用者要求、2 證據異常、3 法人解散／撤銷／停業、4 法人代表人異動待重驗、5 身分恢復後待重驗、6 簽章者退役、255 其他。

**身分恢復之後**

- 以平台備援金鑰恢復時，使用者已在新裝置重新即時拍證件＋錄活體影像，後台確認是同一人。恢復執行後，CAFECA 以這次重新驗證**重新簽發**證明（nonce 遞增，發出新的 `Attested`）。
- 找不到有效的重新驗證時，證明會被**暫停**（`Suspended`，原因碼 5），直到使用者重新驗證。
- 依賴方也可以直接監聽 `RecoveryValidator.RecoveryExecuted(address indexed account, bytes32 newKeyId)`，自行決定是否暫停帳戶。

#### 可驗證的實名資料（KYC Credential）

需要姓名、證件類型、國籍，或需要辨識「是不是同一個人」的網站，在登入請求的 `claims` 加上：

| claim | 內容 | 說明 |
| --- | --- | --- |
| `legal_name` | 證件上的姓名 | 後台 OCR 擷取、經自動或人工核准；使用者無法自行填寫 |
| `doc_type` | `national_id`／`resident_permit`／`passport` | 目前支援國民身分證與居留證 |
| `nationality` | ISO 3166-1 alpha-2，例 `TW` | 國民身分證為 `TW`；居留證暫不提供 |
| `entity_ubn`、`entity_name` | 統一編號、商工登記的公司名稱 | 只在「以公司身分」登入時提供（見下方「法人帳戶」） |
| `pairwise_id` | `bytes32` 同一人識別碼 | `HMAC(K_pairwise, kycIdHash ‖ audience)`：同一個人在你的網站永遠相同（換帳戶、恢復後也相同），不同網站之間無法串連，也推不回證號 |

```js
cafeca.signIn({ nonce, claims: ["kyc_level", "legal_name", "pairwise_id"] });
// 後端 cafeca.verify(...) 之後：
// user.claims.legal_name    "陳大文"（使用者沒有開啟時為 null）
// user.claims.pairwise_id   "0x…"（一人多帳戶偵測、黑名單比對用這個，不要用 account）
// user.claims.credential    { signer, signerClass, attestationNonce, issuedAt }（存查用）
```

- 同意畫面會顯示每一項實際要給出去的內容，**預設全部關閉**，使用者逐項開啟。生日、證號、住址一律不提供。
- 錢包以 KYC 簽章者（與 v2 attestation 同一把）簽出 credential，只放使用者開啟的項目。

**Credential 格式（EIP-712）**

```
domain        = { name: "CAFECA KYC Credential", version: "1", chainId, verifyingContract: identityRegistry }
KycCredential = (address account, string audience, string nonce, uint64 attestationNonce, uint256 issuedAt, uint256 expiresAt,
                 string legalName, string docType, string nationality, bytes32 pairwiseId, string entityUbn, string entityName, string disclosed)
```

`disclosed` 是這份 credential 揭露的 claims（排序、逗號分隔）；沒有揭露的欄位為空字串，`pairwiseId` 為 0。簽章是一般的 65 bytes secp256k1 簽章（不是 ERC-1271）。

**驗證步驟**（`cafeca.verify` 已內建；其他語言自行實作）：

1. `account`＝登入帳戶，`audience`＝你的 origin，`nonce`＝這次登入的 nonce；現在時間在 `issuedAt`～`expiresAt` 之間（最長 10 分鐘）。
2. `disclosed` 的每一項都必須在 `message.claims` 裡（使用者以 Passkey 簽署的同意範圍）。
3. `recoverTypedDataAddress(...)` 得到的地址＝`identityRegistry.statusOf(account).signer`，而且該簽章者等級不是 `NONE`。
4. `statusOf(account)` 為 `ACTIVE`、`effectiveLevel ≥ 2`，而且 `nonce`＝`attestationNonce`。證明之後被暫停、撤銷或重新簽發，舊的 credential 就不再有效。
5. 正式實名要求 `signerClass == PRODUCTION`（目前都是 `PROTOTYPE`）。

credential 不上鏈，驗證也不經過 CAFECA 伺服器。它只證明「登入當下」的內容；要持續追蹤狀態，請鏡像第 9 節的事件。

#### 法人帳戶（以公司身分登入）

使用者可以在錢包建立公司帳戶，以統一編號通過商工登記驗證後，選擇「以公司身分」登入你的網站。對網站來說：

- `user.account` 是**公司帳戶的地址**（與代表人或經辦的個人帳戶不同），交易所帳本請以它為主鍵。
- `user.claims.kyc.subjectType === "entity"`，`effectiveLevel === 2` 表示公司已通過驗證而且狀態有效。
- 要求 `entity_ubn`、`entity_name` 時，資料在 KYC Credential 裡（驗證方式同上）。
- 登入簽章仍是 ERC-1271：公司帳戶的 validator 是 `MemberValidator`，由一位成員以自己的 Passkey 代簽；`cafeca.verify` 不需要任何修改。

**驗證與監控**

- 經濟部商工登記公示資料依統編查詢，公司狀況必須是「核准設立」。
- 申請人的證件姓名與登記代表人相同時自動通過；不同時需上傳代表人授權書，由 CAFECA 人工複核。
- 也可以用公司的**工商憑證**綁定（桌機＋讀卡機＋ HiPKI 跨平台網頁元件）：以憑證簽署 CAFECA 產生的一次性綁定請求，統一編號取自憑證（`Subject serialNumber` 與 Subject Directory Attributes `2.16.886.1.100.2.101`），CAFECA 驗證憑證鏈（MOEACA → GRCA）、效期與 CRL 後直接通過，不需比對代表人姓名。
- 一個統編只能綁一個公司帳戶。
- 每天重新查詢：公司狀況改變 → `Revoked`（原因碼 3）；代表人或登記事項變更 → `Suspended`（原因碼 4），重新驗證後恢復。

**成員與稽核**

- 成員是其他 CAFECA 身分，每位都必須是有效 L2。管理者可以新增、移除成員；經辦只能轉帳與授權代幣。
- 每一筆公司交易都發出 `MemberValidator.MemberAuthorized(entity, member, userOpHash)`，查得到是哪一位成員簽的。
- 成員簽的是 `keccak256(abi.encode(keccak256("CAFECA_ENTITY_V1"), chainId, memberValidator, entity, hash))`，所以成員個人的簽章不能當成公司簽章，反過來也不行。
- 公司被暫停或撤銷後不能轉出資金；額度只能由 CAFECA 調整。

目前只支援公司登記；商業登記（行號）、有限合夥與財團／社團法人之後加入。

**舊版 AttestationRegistry（v1）**：只保留給 CAFECA 內部的綁卡門檻使用。v1 沒有 nonce、不能撤銷，而且**舊簽章可以被任何人重送**（撤銷後重送就會恢復成 L2），依賴方不應再讀 v1。

### 10. 範例網站

```bash
cd app
npm run dev            # CAFECA 錢包：http://localhost:10002
npm run demo:signin    # 範例第三方網站「咖啡豆小舖」：http://localhost:10003
```

範例（[`app/examples/signin-demo/server.ts`](app/examples/signin-demo/server.ts)）示範了彈出視窗、整頁導向與跨裝置 QR code 三種登入方式、nonce 管理與 `cafeca-site.json`，以及登入後透過簽章通道簽署會員條款、EIP-712 訂單與付款 12 TWDC（彈出視窗與中繼兩種傳遞方式）。

可用的環境變數：

- `CAFECA_WALLET`：錢包網址
- `RPC_URL`：驗證用的 RPC
- `PORT`：範例網站的連接埠

錢包端的 `/.well-known/cafeca-configuration`：

- 對外網址：`PUBLIC_ORIGIN`（例：`https://cafeca.io`）。沒有設定時依反向代理的 `X-Forwarded-Host`／`X-Forwarded-Proto` 推算；部署在代理後方請務必設定，否則可能公布成 `http://localhost:10002`。
- 公開 RPC：`PUBLIC_RPC_URL`。沒有設定時公布錢包自己的唯讀 RPC 代理 `<PUBLIC_ORIGIN>/api/rpc`（只允許 `eth_call`、`eth_getLogs` 等讀取方法，開放 CORS）。`https://boltchain.cafeca.io` 是區塊鏈瀏覽器，不是 RPC。
