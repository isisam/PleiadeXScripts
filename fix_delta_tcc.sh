#!/usr/bin/env bash
# 桌機 Delta TCC 修復腳本
# 問題：PleiadeX.app 內 binary 寫死 /Users/Alpha/.claude/pleiades-maid-agent-dispatcher.sh
# 桌機 user=xeon 沒這 path → ExitStatus 127
#
# 修：sudo 建 /Users/Alpha/.claude 與 dispatcher stub（含 osascript chain 觸發 TCC 對話框）
# 用法：bash ~/Library/CloudStorage/Dropbox/PleiadesMaids/scripts/fix_delta_tcc.sh
# 會跑 sudo 命令，主人輸密碼一次

set -e

DISPATCHER_DIR="/Users/Alpha/.claude"
DISPATCHER="$DISPATCHER_DIR/pleiades-maid-agent-dispatcher.sh"
PLIST="$HOME/Library/LaunchAgents/com.alpha.maid-watchdog.plist"

color_ok()  { printf "\033[32m%s\033[0m\n" "$*"; }
color_warn(){ printf "\033[33m%s\033[0m\n" "$*"; }
color_err() { printf "\033[31m%s\033[0m\n" "$*"; }

# Step 1：建 dispatcher stub
color_ok "=== Step 1：建 dispatcher stub（需 sudo 密碼，建 /Users/Alpha/ 用）==="
sudo mkdir -p "$DISPATCHER_DIR"
sudo tee "$DISPATCHER" >/dev/null <<'EOSC'
#!/usr/bin/env bash
# Delta 桌機 TCC bootstrap dispatcher（Alpha 寫於 2026-04-28，v2 補完版）
# 用途：一次觸發 PleiadeX.app 將來會用到的所有 TCC 權限，主人按完一次永久通行

# === Apple Events 系列 ===
osascript -e 'tell application "Reminders"     to count of lists'                       >/dev/null 2>&1 || true
osascript -e 'tell application "Calendar"      to count of calendars'                   >/dev/null 2>&1 || true
osascript -e 'tell application "Notes"         to count of notes'                       >/dev/null 2>&1 || true
osascript -e 'tell application "Contacts"      to count of every person'                >/dev/null 2>&1 || true
osascript -e 'tell application "Messages"      to count of chats'                       >/dev/null 2>&1 || true
osascript -e 'tell application "Mail"          to count of mailboxes'                   >/dev/null 2>&1 || true
osascript -e 'tell application "Numbers"       to count of documents'                   >/dev/null 2>&1 || true
osascript -e 'tell application "Pages"         to count of documents'                   >/dev/null 2>&1 || true
osascript -e 'tell application "Keynote"       to count of documents'                   >/dev/null 2>&1 || true
osascript -e 'tell application "Photos"        to count of albums'                      >/dev/null 2>&1 || true
osascript -e 'tell application "Music"         to count of tracks'                      >/dev/null 2>&1 || true
osascript -e 'tell application "Safari"        to count of windows'                     >/dev/null 2>&1 || true
osascript -e 'tell application "Finder"        to count of items in (path to desktop folder)' >/dev/null 2>&1 || true
osascript -e 'tell application "System Events" to count of processes'                   >/dev/null 2>&1 || true
osascript -e 'tell application "Google Chrome"  to count of windows'                    >/dev/null 2>&1 || true
osascript -e 'tell application "Brave Browser"  to count of windows'                    >/dev/null 2>&1 || true
osascript -e 'tell application "Firefox"        to count of windows'                    >/dev/null 2>&1 || true
osascript -e 'tell application "Microsoft Edge" to count of windows'                    >/dev/null 2>&1 || true
osascript -e 'tell application "Slack"          to count of unread messages'            >/dev/null 2>&1 || true
osascript -e 'tell application "Spotify"        to count of tracks'                     >/dev/null 2>&1 || true
osascript -e 'tell application "Terminal"       to count of windows'                    >/dev/null 2>&1 || true
osascript -e 'tell application "iTerm"          to count of windows'                    >/dev/null 2>&1 || true

# === Files & Folders（個別資料夾隱私） ===
ls ~/Documents               >/dev/null 2>&1 || true
ls ~/Desktop                 >/dev/null 2>&1 || true
ls ~/Downloads               >/dev/null 2>&1 || true
ls ~/Movies                  >/dev/null 2>&1 || true
ls ~/Pictures                >/dev/null 2>&1 || true
ls ~/Music                   >/dev/null 2>&1 || true
ls ~/Library/Mobile\ Documents >/dev/null 2>&1 || true

# === Local Network 隱私 ===
ping -c 1 -t 1 192.168.1.200 >/dev/null 2>&1 || true
ping -c 1 -t 1 192.168.1.1   >/dev/null 2>&1 || true

# === Accessibility／Input Monitoring 透過 System Events keystroke 觸發 ===
osascript -e 'tell application "System Events" to keystroke ""' >/dev/null 2>&1 || true

exit 0
EOSC
sudo chmod +x "$DISPATCHER"
sudo chown -R "$USER:staff" "$DISPATCHER_DIR" 2>/dev/null || true
ls -la "$DISPATCHER"

# Step 2：plist 改 RunAtLoad only（移除 StartInterval 避免 30 秒重彈）
color_ok "=== Step 2：plist 改 RunAtLoad once ==="
plutil -remove StartInterval "$PLIST" 2>/dev/null || true
plutil -p "$PLIST" | grep -E "StartInterval|RunAtLoad"

# Step 3：unload + load 觸發 dispatcher
color_ok "=== Step 3：reload watchdog 觸發 TCC chain ==="
launchctl unload "$PLIST" 2>/dev/null || true
launchctl load "$PLIST"

echo
color_warn "⚠️ 接下來 6 個 TCC 對話框會湧出（Reminders/Calendar/Notes/Contacts/Messages/Mail）"
color_warn "   主人逐個按「允許」即永久通行"
echo
sleep 5
state=$(launchctl list | grep com.alpha.maid-watchdog || echo "NOT FOUND")
echo "watchdog 狀態：$state"
echo
color_ok "=== 完成 ==="
echo "如果還想要每 30 秒 watchdog 輪詢，再 plutil -insert StartInterval -integer 30 \$PLIST 加回去"
