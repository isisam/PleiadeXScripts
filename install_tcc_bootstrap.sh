#!/usr/bin/env bash
# 安裝 tcc-bootstrap 機制（給 Alpha/Beta/Gamma 等有自家真實 dispatcher.sh 的姊妹用）
# 對「桌機 Delta」這種 stub dispatcher 不適用（請改跑 fix_delta_tcc.sh）
#
# 動作：
#   1. patch ~/.claude/pleiades-maid-agent-dispatcher.sh 加 tcc-bootstrap case
#   2. 寫 ~/Library/LaunchAgents/com.<role>.tcc-bootstrap.plist
#   3. launchctl load 觸發一次性 chain
#
# 用法：ROLE=Maia bash ~/Library/CloudStorage/Dropbox/PleiadesMaids/scripts/install_tcc_bootstrap.sh

set -e

ROLE="${ROLE:-Alcyone}"
ROLE_LC=$(echo "$ROLE" | tr '[:upper:]' '[:lower:]')
APP_PATH="$HOME/Applications/PleiadeX $ROLE.app/Contents/MacOS/PleiadeX"
DISP="$HOME/.claude/pleiades-maid-agent-dispatcher.sh"
PLIST="$HOME/Library/LaunchAgents/com.${ROLE_LC}.tcc-bootstrap.plist"

color_ok()  { printf "\033[32m%s\033[0m\n" "$*"; }
color_warn(){ printf "\033[33m%s\033[0m\n" "$*"; }
color_err() { printf "\033[31m%s\033[0m\n" "$*"; }

# 檢查 dispatcher 存在
if [[ ! -f "$DISP" ]]; then
  color_err "找不到 $DISP（自家真實 dispatcher.sh）"
  color_err "若是 stub dispatcher 場景請改用 fix_delta_tcc.sh"
  exit 1
fi

# 檢查 .app binary 存在
if [[ ! -f "$APP_PATH" ]]; then
  color_err "找不到 $APP_PATH"
  color_err "請先確認 ROLE=$ROLE 對應的 .app 已 rename／部署完成"
  exit 1
fi

# Step 1：patch dispatcher.sh 加 tcc-bootstrap case
color_ok "=== Step 1：patch dispatcher.sh 加 tcc-bootstrap case ==="
if grep -q '^  tcc-bootstrap)' "$DISP"; then
  color_warn "  dispatcher.sh 已有 tcc-bootstrap case，跳過"
else
  cp "$DISP" "$DISP.bak.20260428"
  # 在「  noop|""」case 前面插入 tcc-bootstrap case
  python3 -c "
import sys
disp = '$DISP'
with open(disp, 'r', encoding='utf-8') as f:
    content = f.read()
block = '''  tcc-bootstrap)
    log \"INFO: tcc-bootstrap chain 開始\"
    osascript -e 'tell application \"Reminders\"     to count of lists'                       >/dev/null 2>&1 || true
    osascript -e 'tell application \"Calendar\"      to count of calendars'                   >/dev/null 2>&1 || true
    osascript -e 'tell application \"Notes\"         to count of notes'                       >/dev/null 2>&1 || true
    osascript -e 'tell application \"Contacts\"      to count of every person'                >/dev/null 2>&1 || true
    osascript -e 'tell application \"Messages\"      to count of chats'                       >/dev/null 2>&1 || true
    osascript -e 'tell application \"Mail\"          to count of mailboxes'                   >/dev/null 2>&1 || true
    osascript -e 'tell application \"Numbers\"       to count of documents'                   >/dev/null 2>&1 || true
    osascript -e 'tell application \"Pages\"         to count of documents'                   >/dev/null 2>&1 || true
    osascript -e 'tell application \"Keynote\"       to count of documents'                   >/dev/null 2>&1 || true
    osascript -e 'tell application \"Photos\"        to count of albums'                      >/dev/null 2>&1 || true
    osascript -e 'tell application \"Music\"         to count of tracks'                      >/dev/null 2>&1 || true
    osascript -e 'tell application \"Safari\"        to count of windows'                     >/dev/null 2>&1 || true
    osascript -e 'tell application \"Finder\"        to count of items in (path to desktop folder)' >/dev/null 2>&1 || true
    osascript -e 'tell application \"System Events\" to count of processes'                   >/dev/null 2>&1 || true
    osascript -e 'tell application \"Google Chrome\"  to count of windows'                    >/dev/null 2>&1 || true
    osascript -e 'tell application \"Brave Browser\"  to count of windows'                    >/dev/null 2>&1 || true
    osascript -e 'tell application \"Firefox\"        to count of windows'                    >/dev/null 2>&1 || true
    osascript -e 'tell application \"Microsoft Edge\" to count of windows'                    >/dev/null 2>&1 || true
    osascript -e 'tell application \"Slack\"          to count of unread messages'            >/dev/null 2>&1 || true
    osascript -e 'tell application \"Spotify\"        to count of tracks'                     >/dev/null 2>&1 || true
    osascript -e 'tell application \"Terminal\"       to count of windows'                    >/dev/null 2>&1 || true
    osascript -e 'tell application \"iTerm\"          to count of windows'                    >/dev/null 2>&1 || true
    ls \"\$HOME/Documents\"               >/dev/null 2>&1 || true
    ls \"\$HOME/Desktop\"                 >/dev/null 2>&1 || true
    ls \"\$HOME/Downloads\"               >/dev/null 2>&1 || true
    ls \"\$HOME/Movies\"                  >/dev/null 2>&1 || true
    ls \"\$HOME/Pictures\"                >/dev/null 2>&1 || true
    ls \"\$HOME/Music\"                   >/dev/null 2>&1 || true
    ls \"\$HOME/Library/Mobile Documents\" >/dev/null 2>&1 || true
    ping -c 1 -t 1 192.168.1.200       >/dev/null 2>&1 || true
    ping -c 1 -t 1 192.168.1.1         >/dev/null 2>&1 || true
    osascript -e 'tell application \"System Events\" to keystroke \"\"' >/dev/null 2>&1 || true
    log \"INFO: tcc-bootstrap chain 結束\"
    ;;
'''
marker = '  noop|\"\")'
if marker not in content:
    sys.stderr.write('找不到 noop|\"\" case 標記，無法 patch\n')
    sys.exit(1)
new = content.replace(marker, block + marker, 1)
with open(disp, 'w', encoding='utf-8') as f:
    f.write(new)
print('patched')
"
  color_ok "  dispatcher.sh 已 patch"
fi

# Step 2：寫 plist
color_ok "=== Step 2：寫 com.${ROLE_LC}.tcc-bootstrap.plist ==="
cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.${ROLE_LC}.tcc-bootstrap</string>
    <key>ProgramArguments</key>
    <array>
        <string>$APP_PATH</string>
        <string>tcc-bootstrap</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>StandardOutPath</key>
    <string>/tmp/tcc-bootstrap.log</string>
    <key>StandardErrorPath</key>
    <string>/tmp/tcc-bootstrap-error.log</string>
</dict>
</plist>
EOF
echo "  $PLIST 已寫"

# Step 3：load
color_ok "=== Step 3：launchctl load 觸發 chain ==="
launchctl unload "$PLIST" 2>/dev/null || true
launchctl load "$PLIST"
sleep 5
launchctl list | grep "${ROLE_LC}.tcc-bootstrap" || true
echo
color_warn "⚠️ 20+ 個 TCC 對話框會湧出，主人在 PleiadeX $ROLE 桌面逐個按允許"
color_ok "完成"
