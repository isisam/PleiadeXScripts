#!/usr/bin/env bash
# install_mqtt_to_telegram.sh — 一鍵裝 broker↔Telegram bridge（Alpha 機器）
#
# 用法：
#   TELEGRAM_BOT_TOKEN=123:abc bash install_mqtt_to_telegram.sh
#   （也可改 BROKER / TELEGRAM_MASTER_ID 等環境變數覆蓋）
#
# 動作：
#   1. 拉 mqtt_to_telegram_bridge.py 到 ~/.claude/
#   2. 確認 paho-mqtt 已裝
#   3. 寫 com.alphamaid.mqtt-to-telegram launchd plist（KeepAlive=true）
#   4. launchctl load
#
# 部署後：
#   • 訂 pleiadex/broadcast + pleiadex/agents/Xeon/inbox → Telegram DM 主人
#   • 主人 Telegram → publish pleiadex/agents/Xeon/outbox → 所有姊妹 hermes 收到

set -e

TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}"
TELEGRAM_MASTER_ID="${TELEGRAM_MASTER_ID:-1070686431}"
BROKER="${BROKER:-127.0.0.1}"
PORT="${PORT:-1883}"

if [[ -z "$TELEGRAM_BOT_TOKEN" ]]; then
  echo "ERROR: 必須提供 TELEGRAM_BOT_TOKEN（環境變數）" >&2
  echo "用法：TELEGRAM_BOT_TOKEN=123:abc bash $0" >&2
  exit 1
fi

REPO_RAW="https://raw.githubusercontent.com/isisam/PleiadeXScripts/main"
SCRIPT_NAME="mqtt_to_telegram_bridge.py"
LOCAL_SCRIPT="$HOME/.claude/$SCRIPT_NAME"
PLIST="$HOME/Library/LaunchAgents/com.alphamaid.mqtt-to-telegram.plist"
LABEL="com.alphamaid.mqtt-to-telegram"

color_ok()  { printf "\033[32m%s\033[0m\n" "$*"; }
color_warn(){ printf "\033[33m%s\033[0m\n" "$*"; }

color_ok "=== Step 1: 拉 $SCRIPT_NAME ==="
mkdir -p "$HOME/.claude"
# 優先從本地 Dropbox 取（自家 Alpha 跑），失敗才 fallback github
LOCAL_SRC="$HOME/Library/CloudStorage/Dropbox/PleiadesMaids/scripts/$SCRIPT_NAME"
if [[ -f "$LOCAL_SRC" ]]; then
  cp "$LOCAL_SRC" "$LOCAL_SCRIPT"
else
  curl -fsSL "$REPO_RAW/$SCRIPT_NAME" -o "$LOCAL_SCRIPT"
fi
chmod +x "$LOCAL_SCRIPT"
echo "  $LOCAL_SCRIPT ($(wc -l < "$LOCAL_SCRIPT") 行)"

color_ok "=== Step 2: 確認 paho-mqtt 已裝 ==="
PYTHON=/Library/Frameworks/Python.framework/Versions/3.13/Resources/Python.app/Contents/MacOS/Python
if [[ -x "$PYTHON" ]]; then
  "$PYTHON" -m pip install --user --quiet "paho-mqtt==1.6.1" 2>&1 | tail -2 || true
  PY="$PYTHON"
else
  pip3 install --user --quiet --break-system-packages paho-mqtt 2>&1 | tail -2 || true
  PY=$(which python3)
fi
echo "  python: $PY"

color_ok "=== Step 3: 寫 launchd plist $LABEL ==="
mkdir -p "$HOME/Library/LaunchAgents"
launchctl unload "$PLIST" 2>/dev/null || true
cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>$PY</string>
        <string>$LOCAL_SCRIPT</string>
    </array>
    <key>EnvironmentVariables</key>
    <dict>
        <key>TELEGRAM_BOT_TOKEN</key>
        <string>$TELEGRAM_BOT_TOKEN</string>
        <key>TELEGRAM_MASTER_ID</key>
        <string>$TELEGRAM_MASTER_ID</string>
        <key>PLEIADEX_BROKER</key>
        <string>$BROKER</string>
        <key>PLEIADEX_PORT</key>
        <string>$PORT</string>
    </dict>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>/tmp/mqtt-to-telegram.log</string>
    <key>StandardErrorPath</key>
    <string>/tmp/mqtt-to-telegram-error.log</string>
</dict>
</plist>
EOF
chmod 600 "$PLIST"  # 含 token，限本人讀
echo "  $PLIST 已寫（含 token，chmod 600）"

color_ok "=== Step 4: launchctl load ==="
launchctl load "$PLIST"
sleep 3
launchctl list | grep "mqtt-to-telegram" || color_warn "  list 沒看到，看 log /tmp/mqtt-to-telegram.log"

color_ok "=== 完成 ==="
echo
color_warn "驗證："
echo "  • MQTT→Telegram 端：mosquitto_pub -h $BROKER -t pleiadex/agents/Xeon/inbox \\"
echo "      -m '{\"from\":\"Alpha\",\"text\":\"主人 bridge 測試\",\"msg_id\":\"bt-`date +%s`\"}'"
echo "    → 主人 Telegram 應收到 DM"
echo "  • Telegram→MQTT 端：主人在 Telegram bot 對話送任意文字"
echo "    → mosquitto_sub -h $BROKER -t pleiadex/agents/Xeon/outbox 應看到 publish"
echo
echo "log：tail -f /tmp/mqtt-to-telegram.log"
