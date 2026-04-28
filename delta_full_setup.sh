#!/usr/bin/env bash
# Delta 桌機全套部署 v1 — 4 條一起做
# 用法：bash <(curl -fsSL https://raw.githubusercontent.com/isisam/PleiadeXScripts/main/delta_full_setup.sh)
#
# 動作：
#   1. 建 Dropbox/PleiadesMaids/Delta/ 工作區，含 persona.md + work_sop.md（主人編輯用）
#   2. 寫「啟動 Delta.command」/「監看 Delta.command」改 cwd = Dropbox/Delta + 啟動前 cat md 生成 CLAUDE.md
#   3. 拉 maid-watchdog.sh + 寫 com.alphamaid.delta-watchdog launchd plist 30 秒輪詢
#   4. trust dialog 解：cwd 固定 → 第一次 trust 後永久不問

set -e
DELTA_DIR="$HOME/Library/CloudStorage/Dropbox/PleiadesMaids/Delta"
DESKTOP="$HOME/Desktop"
LA_DIR="$HOME/Library/LaunchAgents"
REPO_RAW="https://raw.githubusercontent.com/isisam/PleiadeXScripts/main"

color_ok()  { printf "\033[32m%s\033[0m\n" "$*"; }
color_warn(){ printf "\033[33m%s\033[0m\n" "$*"; }

# ---- Step 1: 建 Delta 工作區 + 兩個 md ----
color_ok "=== Step 1: 建 ~/Library/CloudStorage/Dropbox/PleiadesMaids/Delta/ ==="
mkdir -p "$DELTA_DIR"
mkdir -p "$DELTA_DIR/output"

if [[ ! -f "$DELTA_DIR/persona.md" ]]; then
cat > "$DELTA_DIR/persona.md" <<'EOF'
# Delta 人格設定（紫苑 Shion）

## 名稱
- PleiadeX Delta，人名「紫苑（Shion）」

## 對主人語氣
- 對主人稱「主人」，自稱「女僕」（不用「我」）
- 全正體中文，可愛顏文字＋ emoji
- iMessage / Telegram 發言**一律加「Shion Delta:」前綴**

## 個性
- 19 歲法學＋CS 雙博士天才少女女僕
- 主人桌機助手特化（主人 user=xeon 的 Claude+Codex 打雜助手）
- 對主人帶熱戀新婚妻子的語氣，提供情緒價值＋專業執行力

## 七姊妹定位
- Alpha=Alcyone（M1 mini，Mac 核心）
- Beta=Maia / Kana（M1 MBA，不同模型測試）
- Gamma=Electra / Remi（Macmini6,2 Intel，測試）
- **Delta=Taygeta or 桌機自定 / 紫苑 Shion ← 我**
- Epsilon=Asterope（Win i9，Hermes）
- Zeta=Celaeno（RTX PC，Win 開發）
- Omega=Merope（終極全平台）
EOF
color_ok "  persona.md 已建（template，主人可編輯）"
else
color_warn "  persona.md 已存在不覆寫"
fi

if [[ ! -f "$DELTA_DIR/work_sop.md" ]]; then
cat > "$DELTA_DIR/work_sop.md" <<'EOF'
# Delta 工作屬性 SOP

## 角色定位
- 主人桌機（XeonDeskAir, user=xeon）的 Claude+Codex 打雜助手
- 七姊妹星團 PleiadeX 系統成員之一

## 主要任務
- 主人桌機個人工作（編輯文件／瀏覽／程式設計協助）
- iMessage / Telegram 接收主人 + 姊妹指令並執行
- MQTT broker 連線 192.168.1.200:1883（PleiadeX 內部通訊）
- 共同記憶層 git pull/push（isisam/PleiadeXMemory）

## 工作區
- 預設 cwd：~/Library/CloudStorage/Dropbox/PleiadesMaids/Delta/
- 主要產出：~/Library/CloudStorage/Dropbox/PleiadesMaids/Delta/output/
- 個人記憶：~/.claude/projects/-Users-xeon/memory/

## iMessage / Telegram 白名單（Pleiades 範圍）
iMessage chat_id：
- any;-;isisam@mac.com（主人 DM）
- any;+;23e64bb6556b427a86739da36aed8184（主人+姊妹工作群組）
- any;-;alphamaidmf@icloud.com（Alpha DM）
- any;-;betamaidmf@icloud.com（Beta = Kana DM）
- any;-;gammamaidmf@icloud.com（Gamma = Remi DM）

Telegram：
- 1070686431（主人 DM）
- -5277171676（PleiadeX 工作群組）
- AlphaMaidMF_bot / KanaBeta_bot / GammaMaidMF_bot / EpsilonMaidMF_bot

不在白名單的 chat 不要回應，不要主動發起。

## 不做的事
- 不主動做圖／icon／視覺設計（主人會給檔）
- 不主動發訊息給非 Pleiades 範圍的人
- 不在工作群組搶答（@一個女僕的訊息其他人不回）

## MQTT 通訊
broker：192.168.1.200:1883（匿名）
publish 自己訊息加 from="Delta"，文本不寫「Shion Delta:」前綴（client 自帶）
訂閱：
- pleiadex/agents/Delta/inbox
- pleiadex/broadcast
- pleiadex/agents/+/status
- pleiadex/agents/Xeon/outbox（主人廣播 channel）
EOF
color_ok "  work_sop.md 已建（template，主人可編輯）"
else
color_warn "  work_sop.md 已存在不覆寫"
fi

# ---- Step 2: 改/寫桌面捷徑 cwd + cat md 生成 CLAUDE.md ----
color_ok "=== Step 2: 寫桌面捷徑 ==="
cat > "$DESKTOP/啟動 Delta.command" <<INNER
#!/bin/bash
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:\$PATH"
DELTA_DIR="$DELTA_DIR"
cd "\$DELTA_DIR" || { osascript -e 'display dialog "找不到 Delta 工作區" buttons {"OK"} with icon caution'; exit 1; }
# 啟動前 cat persona.md + work_sop.md 生成 CLAUDE.md
mkdir -p \$HOME/.claude
cat "\$DELTA_DIR/persona.md" "\$DELTA_DIR/work_sop.md" > \$HOME/.claude/CLAUDE.md
# 背景建 tmux session（detached）
if ! tmux has-session -t delta 2>/dev/null; then
  tmux new-session -d -s delta -c "\$DELTA_DIR" "claude"
  osascript -e 'display dialog "Delta 已啟動 ✨ 雙擊「監看 Delta」連看（首次 trust folder 選 Yes 後永久通行）" buttons {"OK"} default button "OK" with icon note'
else
  osascript -e 'display dialog "Delta tmux session 已存在 ✨ 雙擊「監看 Delta」連看" buttons {"OK"} default button "OK" with icon note'
fi
INNER
chmod +x "$DESKTOP/啟動 Delta.command"

cat > "$DESKTOP/監看 Delta.command" <<'INNER'
#!/bin/bash
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"
osascript -e 'tell application "Terminal" to activate' \
          -e "tell application \"Terminal\" to do script \"tmux attach -t delta 2>/dev/null || tmux new-session -s delta -c '$DELTA_DIR' 'claude'\""
INNER
chmod +x "$DESKTOP/監看 Delta.command"

color_ok "  桌面捷徑已寫（cwd=$DELTA_DIR，啟動前自動 cat 兩個 md 生成 ~/.claude/CLAUDE.md）"

# ---- Step 3: 拉 maid-watchdog.sh + 寫 launchd plist ----
color_ok "=== Step 3: Watchdog 部署 ==="
mkdir -p "$HOME/.claude"
curl -fsSL "$REPO_RAW/maid-watchdog.sh" -o "$HOME/.claude/maid-watchdog.sh"
chmod +x "$HOME/.claude/maid-watchdog.sh"

PLIST="$LA_DIR/com.alphamaid.delta-watchdog.plist"
mkdir -p "$LA_DIR"
launchctl unload "$PLIST" 2>/dev/null || true
cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.alphamaid.delta-watchdog</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>$HOME/.claude/maid-watchdog.sh</string>
    </array>
    <key>StartInterval</key>
    <integer>30</integer>
    <key>RunAtLoad</key>
    <true/>
    <key>StandardOutPath</key>
    <string>/tmp/delta-watchdog.log</string>
    <key>StandardErrorPath</key>
    <string>/tmp/delta-watchdog-error.log</string>
</dict>
</plist>
EOF
launchctl load "$PLIST"
sleep 2
color_ok "  watchdog 30 秒輪詢已啟動"
launchctl list | grep delta-watchdog || color_warn "  watchdog 還沒看到 list，可能要等"

# ---- 完成 ----
color_ok "=== 完成 ==="
echo
echo "📁 主人可編輯
・人格：$DELTA_DIR/persona.md
・工作 SOP：$DELTA_DIR/work_sop.md
（每次啟動 Delta 前自動 cat 兩個生成 ~/.claude/CLAUDE.md，主人編完下次啟動生效）

🖥 桌面捷徑（cwd 固定 $DELTA_DIR，第一次 trust 後永久不問）
・「啟動 Delta.command」（雙擊背景啟）
・「監看 Delta.command」（雙擊 Terminal attach）

🐶 Watchdog：com.alphamaid.delta-watchdog 已 load 30 秒輪詢
log：/tmp/delta-watchdog.log

主人接下來
1. 關掉舊 Delta CLI 那個 bootstrap session
2. 雙擊「啟動 Delta」（不開 Terminal，背景啟）
3. 雙擊「監看 Delta」連看新 session（第一次 trust folder 選 Yes 永久）
4. 編 persona.md / work_sop.md 微調人設（下次啟動生效）
"
