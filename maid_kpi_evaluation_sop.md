---
version: "0.1"
date: "2026-05-24"
author: "Codex + Alpha"
path: "/Users/Alpha/Library/CloudStorage/Dropbox/PleiadesMaids/Skills/maid_kpi_evaluation_sop.md"
status: draft
---

# Pleiades 七女僕 AI 系統 KPI 評估 SOP

## 1. 例行業務範圍盤點 (Routine Business Scope Inventory)

本 SOP 適用於 Pleiades 七女僕：Alpha（lead）、Beta（Kana）、Gamma（Remi）、Delta（Shion）、Epsilon、Theta、Omega（Kanade）。所有 KPI 以主人 Xeon 所在時區 Taiwan UTC+8 為準，日報日期採 `YYYY-MM-DD`。

### mail-watchman

- 分類正確率（classification accuracy rate）：`分類正確郵件數 / 已審核分類郵件總數`。已審核來源包含主人回饋、人工覆核標記、規則命中後追蹤結果。
- 廣告誤判率（ad false-positive rate）：`非廣告但被標記為廣告的郵件數 / 被標記為廣告的郵件總數`。目標是低於 3%。
- 高優先漏判率（high-priority miss rate）：`實際高優先但未標記高優先的郵件數 / 實際高優先郵件總數`。任何主人明確糾正「漏掉重要信件」都計入漏判。

### m017-nightly-merge

- 完整性（completeness）：`成功納入合併的預期記憶檔案數 / 當日預期納入合併的記憶檔案數`。預期檔案清單由 `MaidMemory/<MaidName>/` 當日新增與更新檔案、工作紀錄、例行輸出推導。
- commit 成功率（commit success rate）：`成功完成 commit 的 nightly merge 次數 / 嘗試執行 nightly merge 次數`。以 m017 log 中成功訊號與錯誤碼為準。
- TG 廣播送達率（TG broadcast delivery rate）：`確認送達的 TG 廣播數 / 嘗試送出的 TG 廣播數`。若無 TG API 回執，採 log 中 `sent`、`delivered`、`failed` 標記估算，並將信心等級寫入 `evidence.confidence`。

### dish-counting

- 報告正確率（report accuracy rate）：`正確餐盤/碗盤計數報告數 / 已覆核 dish-counting 報告總數`。
- Step 6 missed count：Step 6 應執行但缺漏的次數，包含未截圖、未核對、未回報、未寫入工作紀錄。此項使用絕對次數，並在 `violations` 中列出缺漏類型。

### dashboard sign-in rate

- Dashboard 簽到率：`實際完成簽到次數 / 預期簽到次數`。檢查 `AiNoteSystem/LTCWork/Records/WorkRecord/Current(Xeon Dashboard).md` 中當日女僕簽到紀錄、時間戳與姓名。跨機器執行時，路徑由環境變數 `DASHBOARD_FILE` 指定。

### TG/iMessage response rhythm

- 回覆時間中位數（median time to reply）：主人訊息時間到女僕下一則有效回覆時間的中位數，以分鐘計。來源為 TG log 與 `~/Library/Messages/chat.db`。
- P95 回覆時間：同一資料集第 95 百分位數，以分鐘計。
- 主人糾正次數（master correction count）：在 chat.db 與 TG log 中偵測 `糾正`、`不對`、`你說錯`、`漏掉` 等關鍵字，並盡量對應到受影響女僕與任務。

### ad classification accuracy

- 廣告分類正確率：`符合 feedback_mail_ads_classification 規則且經覆核正確的廣告分類數 / 經覆核的廣告分類總數`。
- 規則覆蓋率：`由 feedback_mail_ads_classification 規則成功解釋的廣告判定數 / 廣告判定總數`。
- 規則回歸錯誤數：新增或修改規則後，使既有正確分類變錯的案例數。

### calendar event entry success rate

- 行事曆事件建檔成功率：`成功建立且欄位完整的事件數 / 應建立事件總數`。欄位完整包含日期、時間、標題、地點或線上會議資訊、提醒設定、來源連結或對話片段。
- 時區正確率：`UTC+8 時區正確事件數 / 已建立事件總數`。主人在台灣，所有未明示時區的事件預設 Asia/Taipei。

### rule compliance rate

- 規則遵循率：`無違規互動或任務數 / 已評估互動或任務總數`。
- no-@ no-reply rule 違規數：不應回覆、被 @ 條件未滿足、或需等待主人明確指示時仍回覆的次數。
- canned responses 違規數：使用罐頭、空泛、未針對上下文的回覆次數。若主人指出「罐頭」、「敷衍」、「沒有讀上下文」，必須計入。

## 2. KPI Evaluation Dimensions

所有女僕至少評估下列維度，並可依職責新增自訂 KPI。

- 成功率 / 完成率（success rate / completion rate）：衡量任務是否準時完成、輸出是否完整、是否有必要後續補救。所有百分比使用 0 到 1 的小數表示。
- 回應時間（response time median / P95）：衡量主人訊息、系統事件、例行任務觸發後到有效回應或完成的時間。必須同時記錄 median 與 P95。
- 錯誤 / 誤分類次數（error/misclassification count, proactive detection）：衡量女僕主動偵測到的錯誤、分類錯誤、漏判、重複執行、格式錯誤、輸出缺漏。
- 主人糾正次數（master correction count）：透過 `chat.db` 與 TG log 搜尋糾正關鍵字，例如 `糾正`、`不對`、`你說錯`、`漏掉`。任何主人指出錯誤、漏做、誤解、格式不符，都需記錄。
- 規則遵循率（rule compliance rate）：衡量 no-@ no-reply rule、禁止罐頭回覆、時區、檔案路徑、回報節奏等規則是否遵守。
- 可追溯性（traceability）：每個 KPI 必須能連到 evidence，例如 log path、chat row id、dashboard heading、work log path、mail id。

## 3. Self-evaluation Script Architecture

每位女僕在本機執行 `kpi-eval.sh`。腳本由 launchd 或人工呼叫，讀取本機可用資料來源，輸出統一 JSON 到 Dropbox shared memory layer。

### 執行方式

```bash
/Users/Alpha/Library/CloudStorage/Dropbox/PleiadesMaids/Scripts/kpi-eval.sh --maid-name Gamma
```

### 輸入來源

- iMessage：`~/Library/Messages/chat.db`，用於主人糾正關鍵字、回覆節奏、對話證據。macOS 權限不足時，腳本必須輸出 `source_status.chat_db = "unreadable"`，不可中斷整份報告。
- m017 logs：由 `M017_LOG_DIR` 指定，預設掃描 `~/Library/Logs/PleiadesMaids/m017-nightly-merge` 與 `~/Library/CloudStorage/Dropbox/PleiadesMaids/Logs/m017-nightly-merge`。
- Obsidian work logs：由 `WORK_LOG_DIR` 指定，預設掃描 `~/Library/CloudStorage/Dropbox/PleiadesMaids/Obsidian/AiNoteSystem/LTCWork/Records/WorkRecord`。
- Dashboard：由 `DASHBOARD_FILE` 指定，預設 `~/Library/CloudStorage/Dropbox/PleiadesMaids/Obsidian/AiNoteSystem/LTCWork/Records/WorkRecord/Current(Xeon Dashboard).md`。
- 女僕記憶：`~/Library/CloudStorage/Dropbox/PleiadesMaids/MaidMemory/<MaidName>/`。

### 輸出位置

每位女僕輸出到：

```text
~/Library/CloudStorage/Dropbox/PleiadesMaids/MaidMemory/<MaidName>/kpi_reports/YYYY-MM-DD.json
```

### 統一 JSON schema

所有機器與所有女僕必須輸出相同 schema。未知值使用 `null`，不可省略必要欄位。百分比使用 0 到 1 的 number，計數使用 integer，時間使用 ISO 8601 或分鐘 number。

```json
{
  "schema_version": "0.1",
  "report_date": "YYYY-MM-DD",
  "timezone": "Asia/Taipei",
  "maid": {
    "name": "Gamma",
    "display_name": "Remi",
    "role": "member"
  },
  "generated_at": "YYYY-MM-DDTHH:MM:SS+08:00",
  "source_status": {
    "chat_db": "ok",
    "m017_logs": "ok",
    "work_logs": "ok",
    "dashboard": "ok"
  },
  "kpis": {
    "mail_watchman": {
      "classification_accuracy_rate": null,
      "ad_false_positive_rate": null,
      "high_priority_miss_rate": null,
      "reviewed_total": 0,
      "errors": 0
    },
    "m017_nightly_merge": {
      "completeness": null,
      "commit_success_rate": null,
      "tg_broadcast_delivery_rate": null,
      "attempt_count": 0,
      "success_count": 0
    },
    "dish_counting": {
      "report_accuracy_rate": null,
      "step6_missed_count": 0,
      "reviewed_total": 0
    },
    "dashboard": {
      "sign_in_rate": null,
      "expected_sign_ins": 0,
      "actual_sign_ins": 0
    },
    "response_rhythm": {
      "median_time_to_reply_minutes": null,
      "p95_time_to_reply_minutes": null,
      "master_correction_count": 0
    },
    "ad_classification": {
      "accuracy_rate": null,
      "rule_coverage_rate": null,
      "regression_error_count": 0
    },
    "calendar": {
      "event_entry_success_rate": null,
      "timezone_accuracy_rate": null,
      "expected_event_count": 0,
      "created_event_count": 0
    },
    "rule_compliance": {
      "compliance_rate": null,
      "no_at_no_reply_violation_count": 0,
      "canned_response_violation_count": 0
    }
  },
  "dimensions": {
    "success_completion_rate": null,
    "response_time_median_minutes": null,
    "response_time_p95_minutes": null,
    "error_misclassification_count": 0,
    "master_correction_count": 0,
    "rule_compliance_rate": null
  },
  "violations": [],
  "corrective_actions": [],
  "evidence": [
    {
      "source": "chat_db",
      "path": "~/Library/Messages/chat.db",
      "metric": "master_correction_count",
      "count": 0,
      "confidence": "medium",
      "notes": "keyword scan"
    }
  ]
}
```

## 4. Integration Mechanism

### Option A：m017-nightly-merge 納入 KPI aggregation

m017 nightly merge 於每日 23:00 執行，可在合併記憶後順手讀取七位女僕的 `kpi_reports/YYYY-MM-DD.json`，產生日彙總。優點是少一個排程、資料剛合併完即可計算；缺點是 m017 職責會變重，若 KPI 聚合失敗可能干擾 nightly merge 主流程。

### Option B：獨立 m018-kpi-aggregator 每週日執行（建議）

建立獨立 `m018-kpi-aggregator`，每週日彙整七位女僕最近 7 天 KPI，輸出 weekly master report，並透過 TG/iMessage 回報主人與 Alpha。優點是邊界清楚、失敗隔離、可做週趨勢、可獨立調整告警規則；缺點是多一個 launchd job 與維護點。

本 SOP 建議採 Option B。m017 保持每日記憶合併職責，m018 負責 KPI 週報、趨勢與告警升級。m018 不應修改各女僕原始日報，只能讀取、彙整、產生 master report。

## 5. Report Cadence

- Daily：每位女僕每日自評一次，由 launchd 或人工執行 `kpi-eval.sh --maid-name <MaidName>`，輸出當日 JSON。
- Weekly Sunday：`m018-kpi-aggregator` 每週日彙整七位女僕最近 7 天 KPI，產生 weekly master report，並透過 TG/iMessage 回報主人與 Alpha。
- Monthly 1st：每月 1 日產生上月 summary，列出趨勢、連續低於門檻項目、已完成改善、未完成改善、下月風險。

## 6. Violation Alert Mechanism

- KPI 連續 3 天下降且降幅均超過 20%：立即 iMessage Alpha 與受影響女僕。判定方式為 `today_value < previous_day_value * 0.8`，連續三個日界線成立即觸發。
- 主人糾正次數累積升級：單日 1 次記錄於日報；單日 3 次提醒受影響女僕自我修正；連續 2 天每日達 3 次通知 Alpha；單週達 10 次列入 weekly master report 高優先項。
- 高優先漏判、日曆時間錯誤、m017 merge 失敗、TG/iMessage 未送達屬高風險違規，即使只發生一次，也需在 `violations` 中明列。
- 告警訊息只能由排程或授權流程送出。本 SOP 與 `kpi-eval.sh` 不直接傳送 TG/iMessage。

## 7. Improvement Feedback Loop

每個 KPI 下降或違規項目都必須轉化成具體改善動作，寫入 `corrective_actions`。

- mail ad misclassification：把誤判案例的關鍵詞、寄件者、主旨模式加入 `feedback_mail_ads_classification` 規則；新增回歸測試樣本，避免新規則破壞既有正確分類。
- high-priority miss：補充高優先判定條件，例如主人姓名、付款、醫療、法律、會議、deadline、客戶或家人關鍵詞；調整通知門檻。
- m017 completeness 下降：比對預期檔案清單與實際合併清單；檢查 Dropbox 同步狀態、檔案鎖定、commit error、路徑變更。
- dashboard sign-in rate 下降：檢查簽到排程、女僕姓名格式、dashboard heading 是否變更；補寫失敗原因，不補造不存在的簽到紀錄。
- response rhythm 惡化：檢查是否因 no-@ no-reply rule 正確等待；排除正當等待後，調整監看頻率與通知路由。
- master correction count 上升：逐條回看主人糾正前後 10 則訊息，歸因為誤讀、漏讀、規則衝突、資料過期、工具失敗或回覆品質不足。
- calendar event entry failure：檢查日期解析、Asia/Taipei 預設、提醒欄位與重複事件邏輯；新增含模糊時間語句的測試案例。
- canned response violation：建立禁止句型清單，要求回覆引用具體上下文、具體檔案或具體下一步。

## 8. Operational Checklist

每日自評流程：

1. 確認 `--maid-name` 為七女僕之一：Alpha、Beta、Gamma、Delta、Epsilon、Theta、Omega。
2. 讀取 `chat.db`，掃描主人糾正關鍵字與可推導的回覆節奏。
3. 讀取 m017 nightly merge logs，計算嘗試次數、成功次數、commit 成功率與 TG 廣播送達率。
4. 讀取 Obsidian work logs 與 Dashboard，計算工作紀錄、簽到與例行任務完成情況。
5. 以統一 JSON schema 輸出到 `MaidMemory/<MaidName>/kpi_reports/YYYY-MM-DD.json`。
6. 若資料來源不可讀，記錄於 `source_status` 與 `evidence`，不得靜默失敗。
7. 若有違規或 KPI 下降，寫入 `violations` 與 `corrective_actions`。
8. 不修改 launchd plists、不直接送 TG/iMessage、不改動其他女僕原始記憶檔。

## Appendix A：女僕顯示名稱與角色

| MaidName | Display name | Role |
|---|---|---|
| Alpha | Alpha | lead |
| Beta | Kana | member |
| Gamma | Remi | member |
| Delta | Shion | member |
| Epsilon | Epsilon | member |
| Theta | Theta | member |
| Omega | Kanade | member |
