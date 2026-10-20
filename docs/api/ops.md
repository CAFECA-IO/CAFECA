# 排程與維運 API

由 `deploy:server` 建立的 crontab 或監控系統呼叫。共通規則見 [overview.md](overview.md)。

| 端點 | 方法 | 驗證 | 建議頻率 | 說明 |
|---|---|---|---|---|
| `/api/maintenance` | POST | `x-cafeca-cron` | 每天（預設 03:41） | 見下 |
| `/api/identity/sync` | POST | 不需要 | 每幾分鐘 | 見下 |
| `/api/entity/sync` | POST | 不需要；`?force=1` 需要 `kyc` 人員 | 每天 | 見下 |
| `/api/index/status` | GET | 不需要 | 監控 | 見下 |

## `/api/maintenance`

每天執行以下工作：

- 同意請求逾期失效
- 保存期限到期的證件影像、臉部影片與人臉特徵清除
- 稽核紀錄上鏈

回應：

```json
{ "consentExpired": 0, "casesPurged": 2, "anchor": { "…": "上鏈結果，失敗時是 { \"error\": \"…\" }" } }
```

```bash
curl -X POST https://cafeca.io/api/maintenance -H "x-cafeca-cron: $CRON_SECRET"
```

密鑰缺少或錯誤時回 401。正式模式下沒有設定 `CRON_SECRET` 會被上線閘門擋下。

## `/api/identity/sync`

處理尚未處理的 `RecoveryExecuted` 事件：重新簽發或暫停 v2 證明。只根據鏈上事件與後台 KYC 紀錄動作，可以重複呼叫，所以不需要驗證呼叫者。

## `/api/entity/sync`

法人監控：20 小時內查過的法人會略過；`?force=1` 立即重新查詢全部法人。查到變更時：

- 公司狀況改變：撤銷證明（原因碼 3）
- 代表人或登記事項變更：暫停證明（原因碼 4）

回 `{ supported, results: [[動作, 說明], …] }`。

## `/api/index/status`

`{ lastBlock, head, events, lastSync, lastError, startBlock }`。`head - lastBlock` 持續變大代表索引同步停滯。
