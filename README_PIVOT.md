# PleiadeX Pivot — Telegram user-account event bus（取代 MQTT broker）

主人決策（2026-04-28）：放棄 MQTT broker 為主軸，改用「主人 Telegram user account 跨機 multi-device login」當 event bus。

## 架構

```
        ┌──────────────────────────────────────┐
        │  主人 Telegram user account（一人）  │
        │  在每台姊妹機都同帳號 multi-login    │
        └─────┬──────────┬──────────┬──────────┘
              │          │          │
        Alpha 機     Beta 機     Gamma 機
        Telethon     Telethon    Telethon
        scanner      scanner     scanner
              │          │          │
              ▼          ▼          ▼
        姊妹自家 bot 從 bot 視角回到同 chat
        （所有姊妹 + 主人都看得到彼此）
```

讀：用主人 user session（看得到 bot 發言、所有群組訊息）。
寫：用姊妹自家 bot token（KanaBeta_bot / RemiGamma_bot…）。

## 主人部署 5 步

1. 申請 Telegram API
   - 進 https://my.telegram.org → API development tools
   - 建一個 app，記下 `api_id`（數字）+ `api_hash`（32 字元）

2. 產 user session string（一次）
   ```
   pip install telethon
   export TG_API_ID=12345 TG_API_HASH=xxxxx
   python3 gen_session.py
   ```
   - 輸入手機（含國碼）+ 簡訊驗證碼 + 兩段密碼（若有）
   - 印出的 `1AZ...` 就是 session string，妥善保管

3. 在每台姊妹機跑 install（替換 ROLE / 自家 bot token）
   ```
   ROLE=Beta \
   TG_API_ID=12345 TG_API_HASH=xxxxx \
   TG_USER_SESSION_STRING="1AZ..." \
   AGENT_BOT_TOKEN="123:KanaBeta..." \
   SESSION=claude-imessage \
   bash <(curl -fsSL https://raw.githubusercontent.com/isisam/PleiadeXScripts/main/install_telethon_scanner.sh)
   ```

4. 驗證
   - `tail -f /tmp/<role>-telethon.log` 看到 `logged in as user_id=...` = 通
   - 在 PleiadeX 工作群（chat_id `-5277171676`）發 `@Beta 在嗎` → Beta 機 tmux 主線收到注入

5. 群組擴充
   - 預設只白名單一個 chat（PleiadeX 工作群），要加群改 `PLEIADEX_CHAT_ALLOW="<id1>,<id2>"` 重跑 install

## 安全 caveat（重要）

- **Session string 等同 user 登入權杖**。洩漏 = 別人能讀主人所有 Telegram 訊息（含 DM、私群）。
- **建議**：建一隻 Pleiades 專屬 user account（用備用手機號），主人在這個 account 加入工作群即可，不要用主人本人主帳號。
- plist 已設 `chmod 600`，但 macOS 同 user 的其他 process 仍讀得到。
- Rotate 流程：主人在 Telegram → Settings → Devices → 把對應 session 砍掉，重跑 step 2 + 3。
- 工作群以外 chat 不要 mention 姊妹（白名單擋掉，但仍會走 `events.NewMessage` 回調 → 不消耗 quota 但有日誌雜訊）。

## 與 MQTT 並存

- Telethon scanner 跟 hermes_bridge.py 同 process 不衝突（兩套都是 daemon，各自 launchd plist）。
- 過渡期可雙跑；確認 Telegram 路徑穩定後關 MQTT broker。

## 檔案

- `telethon_scanner.py` — daemon 主體，~155 行
- `gen_session.py` — 一次性 session string 產生器
- `install_telethon_scanner.sh` — 一鍵 launchd 部署
