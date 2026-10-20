# CAFECA 文件

| 文件 | 對象 | 內容 |
|---|---|---|
| [第三方服務串接指南](integration.md) | 要串接 CAFECA 的網站、App、交易所 | 索取用戶授權、取得用戶資訊與 KYC 資料（實名狀態、KYC Credential、資料調閱）、公司身分、檢查清單 |
| [API 總覽與共通規則](api/overview.md) | 所有人 | 網址、四種身分驗證方式、錯誤格式、CORS、速率限制、端點總表 |
| [對外公開 API](api/public.md) | 串接 CAFECA 的網站、依賴方、商家 | `/.well-known/cafeca-configuration`、公開 RPC、簽章通道中繼、依賴方資料調閱、驗票、x402 付費資源、索引查詢 |
| [錢包 API](api/wallet.md) | CAFECA 錢包前端（同源） | 登入、UserOp 代送、實名驗證、條款、額度、代稱、聊天、法人帳戶、實體卡、裝置配對與恢復、AI 代理、Visa 模擬 |
| [管理後台 API](api/admin.md) | 營運人員 | 人員登入與邀請、KYC／法人複核、交易額度、依賴方登記、資料調閱覆核、稽核紀錄、政策與保存期限 |
| [排程與維運 API](api/ops.md) | 部署與監控 | 每日維護、恢復事件同步、法人監控、索引狀態 |

**第一次串接請從[串接指南](integration.md)開始。** 登入協定（`SignIn` EIP-712、ERC-1271 簽章版面）、簽章通道的加密格式與 SDK 用法寫在根目錄 [README](../README.md) 的〈Sign in with CAFECA〉一章；本目錄只描述 HTTP 端點。部署、環境變數與功能對照見 [app/README.md](../app/README.md)。

> 這份文件對應 `app/src/app/api/**/route.ts` 的實作。新增或修改端點時請一併更新對應的文件。
