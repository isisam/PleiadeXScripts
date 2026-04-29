#!/usr/bin/env bash
# PleiadeX Telethon scanner 一鍵裝（每姊妹機跑一次）
#
# 用法（主人或姊妹機本機）：
#   ROLE=Beta \
#   TG_API_ID=12345 TG_API_HASH=xxxx \
#   TG_USER_SESSION_STRING="1AZ..." \
#   AGENT_BOT_TOKEN="123:ABC" \
#   SESSION=claude-imessage \
#   bash install_telethon_scanner.sh
#
# 動作：
#   1. pip install telethon
#   2. 拉 telethon_scanner.py 到 ~/.claude/
#   3. 寫 com.alphamaid.<role-lower>-telethon launchd plist（KeepAlive=true）
#   4. launchctl load 並驗 daemon 跑

set -e
ROLE="${ROLE:-Alpha}"
ROLE_LC=$(echo "$ROLE" | tr '[:upper:]' '[:lower:]')
SESSION="${SESSION:-claude-imessage}"
ALLOW="${PLEIADEX_CHAT_ALLOW:--5277171676}"

REPO_RAW="https://raw.githubusercontent.com/isisam/PleiadeXScripts/main"
PY_DST="$HOME/.claude/telethon_scanner.py"
PLIST="$HOME/Library/LaunchAgents/com.alphamaid.${ROLE_LC}-telethon.plist"

color_ok()   { printf "\033[32m%s\033[0m\n" "$*"; }
color_warn() { printf "\033[33m%s\033[0m\n" "$*"; }
color_err()  { printf "\033[31m%s\033[0m\n" "$*"; }

# 必填檢查
for v in TG_API_ID TG_API_HASH TG_USER_SESSION_STRING AGENT_BOT_TOKEN; do
  if [[ -z "${!v}" ]]; then
    color_err "缺 ENV：$v（必設）"; exit 2
  fi
done

color_ok "=== Step 1: 拉 telethon_scanner.py ==="
mkdir -p "$HOME/.claude"
curl -fsSL "$REPO_RAW/telethon_scanner.py" -o "$PY_DST"
chmod +x "$PY_DST"
echo "  $PY_DST ($(wc -l < "$PY_DST") 行)"

color_ok "=== Step 2: 找 Python 並裝 telethon ==="
PYTHON=/Library/Frameworks/Python.framework/Versions/3.13/Resources/Python.app/Contents/MacOS/Python
if [[ -x "$PYTHON" ]]; then
  "$PYTHON" -m pip install --user --quiet telethon 2>&1 | tail -2
  PY=$PYTHON
else
  pip3 install --user --quiet --break-system-packages telethon 2>&1 | tail -2 || true
  PY=$(which python3)
fi
echo "  python: $PY"

color_ok "=== Step 3: 寫 launchd plist com.alphamaid.${ROLE_LC}-telethon ==="
mkdir -p "$HOME/Library/LaunchAgents"
launchctl unload "$PLIST" 2>/dev/null || true
cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.alphamaid.${ROLE_LC}-telethon</string>
    <key>ProgramArguments</key>
    <array>
        <string>$PY</string>
        <string>$PY_DST</string>
    </array>
    <key>EnvironmentVariables</key>
    <dict>
        <key>PLEIADEX_AGENT</key>
        <string>$ROLE</string>
        <key>TG_API_ID</key>
        <string>$TG_API_ID</string>
        <key>TG_API_HASH</key>
        <string>$TG_API_HASH</string>
        <key>TG_USER_SESSION_STRING</key>
        <string>$TG_USER_SESSION_STRING</string>
        <key>AGENT_BOT_TOKEN</key>
        <string>$AGENT_BOT_TOKEN</string>
        <key>PLEIADEX_CHAT_ALLOW</key>
        <string>$ALLOW</string>
        <key>TELETHON_TMUX_SESSION</key>
        <string>$SESSION</string>
    </dict>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>/tmp/${ROLE_LC}-telethon.log</string>
    <key>StandardErrorPath</key>
    <string>/tmp/${ROLE_LC}-telethon-error.log</string>
</dict>
</plist>
EOF
chmod 600 "$PLIST"   # 含 user session string，限制權限
echo "  $PLIST 已寫（chmod 600）"

color_ok "=== Step 4: launchctl load ==="
launchctl load "$PLIST"
sleep 3
launchctl list | grep "${ROLE_LC}-telethon" || color_warn "  list 沒看到，看 log /tmp/${ROLE_LC}-telethon.log"

color_ok "=== 完成 ==="
echo
color_warn "Telethon scanner 部署完："
echo "  • 用主人 user session 訂閱所有 chat"
echo "  • 過濾 chat_id ∈ {$ALLOW}"
echo "  • 收到 @$ROLE / @all → tmux send-keys 注入 $SESSION"
echo "  • 姊妹自家 bot token 可從 bot 視角發回（bot_send）"
echo "  • dedupe by chat:msg_id（保最近 500 筆）"
echo
echo "log：tail -f /tmp/${ROLE_LC}-telethon.log"
