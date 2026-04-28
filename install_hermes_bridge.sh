#!/usr/bin/env bash
# Hermes bridge 通用部署（給 Beta/Gamma/Delta/Epsilon 等所有姊妹用）
# 用法：
#   ROLE=Beta SESSION=claude-imessage bash install_hermes_bridge.sh
#   ROLE=Delta SESSION=delta bash install_hermes_bridge.sh
#
# 動作：
#   1. 拉 hermes_bridge.py 到 ~/.claude/
#   2. 寫 com.alphamaid.<role-lower>-hermes launchd plist（KeepAlive=true）
#   3. launchctl load
#
# 部署完成後該姊妹的 Claude session（指定 tmux session）會自動收到主人 broker 訊息（@<role> 或 inbox）並注入

set -e
ROLE="${ROLE:-Alpha}"
ROLE_LC=$(echo "$ROLE" | tr '[:upper:]' '[:lower:]')
SESSION="${SESSION:-claude-imessage}"
BROKER="${BROKER:-192.168.1.200}"
PORT="${PORT:-1883}"

REPO_RAW="https://raw.githubusercontent.com/isisam/PleiadeXScripts/main"
HERMES_PY="$HOME/.claude/hermes_bridge.py"
PLIST="$HOME/Library/LaunchAgents/com.alphamaid.${ROLE_LC}-hermes.plist"

color_ok()  { printf "\033[32m%s\033[0m\n" "$*"; }
color_warn(){ printf "\033[33m%s\033[0m\n" "$*"; }

color_ok "=== Step 1: 拉 hermes_bridge.py ==="
mkdir -p "$HOME/.claude"
curl -fsSL "$REPO_RAW/hermes_bridge.py" -o "$HERMES_PY"
chmod +x "$HERMES_PY"
echo "  $HERMES_PY ($(wc -l < "$HERMES_PY") 行)"

color_ok "=== Step 2: 確認 paho-mqtt 已裝 ==="
PYTHON=/Library/Frameworks/Python.framework/Versions/3.13/Resources/Python.app/Contents/MacOS/Python
if [[ -x "$PYTHON" ]]; then
  "$PYTHON" -m pip install --user --quiet "paho-mqtt==1.6.1" 2>&1 | tail -2
  PY=$PYTHON
else
  pip3 install --user --quiet --break-system-packages paho-mqtt 2>&1 | tail -2 || true
  PY=$(which python3)
fi
echo "  python: $PY"

color_ok "=== Step 3: 寫 launchd plist com.alphamaid.${ROLE_LC}-hermes ==="
mkdir -p "$HOME/Library/LaunchAgents"
launchctl unload "$PLIST" 2>/dev/null || true
cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.alphamaid.${ROLE_LC}-hermes</string>
    <key>ProgramArguments</key>
    <array>
        <string>$PY</string>
        <string>$HERMES_PY</string>
    </array>
    <key>EnvironmentVariables</key>
    <dict>
        <key>PLEIADEX_AGENT</key>
        <string>$ROLE</string>
        <key>PLEIADEX_BROKER</key>
        <string>$BROKER</string>
        <key>PLEIADEX_PORT</key>
        <string>$PORT</string>
        <key>HERMES_TMUX_SESSION</key>
        <string>$SESSION</string>
    </dict>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>/tmp/${ROLE_LC}-hermes.log</string>
    <key>StandardErrorPath</key>
    <string>/tmp/${ROLE_LC}-hermes-error.log</string>
</dict>
</plist>
EOF
echo "  $PLIST 已寫"

color_ok "=== Step 4: launchctl load ==="
launchctl load "$PLIST"
sleep 3
launchctl list | grep "${ROLE_LC}-hermes" || color_warn "  list 沒看到，看 log /tmp/${ROLE_LC}-hermes.log"

color_ok "=== 完成 ==="
echo
color_warn "Hermes bridge 部署完："
echo "  • 訂閱 pleiadex/broadcast 與 pleiadex/agents/$ROLE/inbox"
echo "  • 收到自己被 @ 或 DM → tmux send-keys 注入到 $SESSION 給 Claude session 看"
echo "  • dedupe by msg_id（保最近 200 筆）"
echo "  • KeepAlive=true 自動重啟"
echo
echo "log：tail -f /tmp/${ROLE_LC}-hermes.log"
echo
color_warn "驗證：請其他姊妹發 broadcast 含 @$ROLE 或 DM 到 pleiadex/agents/$ROLE/inbox，看 tmux session $SESSION 是否收到注入"
