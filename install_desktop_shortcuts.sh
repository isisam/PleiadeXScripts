#!/usr/bin/env bash
# 桌面雙擊捷徑安裝（v3）：
#   1. 啟動 Delta.command（背景建 tmux session）
#   2. 監看 Delta.command（開 Terminal attach tmux）
#   3. MQTT 聊天.app（真 .app bundle，雙擊跳 Tkinter GUI 視窗，不開 Terminal）
# 用法：bash <(curl -fsSL https://raw.githubusercontent.com/isisam/PleiadeXScripts/main/install_desktop_shortcuts.sh)

set -e
DESKTOP="$HOME/Desktop"
mkdir -p "$DESKTOP"

# ---- 1. 啟動 Delta（背景建 tmux session） ----
cat > "$DESKTOP/啟動 Delta.command" <<'INNER'
#!/bin/bash
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"
cd "$HOME"
if ! command -v tmux >/dev/null 2>&1; then
  osascript -e 'display dialog "需先 brew install tmux\n\n打開 Terminal paste：\nbrew install tmux" buttons {"OK"} default button "OK" with icon caution'
  exit 1
fi
if ! command -v claude >/dev/null 2>&1; then
  osascript -e 'display dialog "需先裝 Claude Code\n\nbrew install node && npm install -g @anthropic-ai/claude-code" buttons {"OK"} default button "OK" with icon caution'
  exit 1
fi
if tmux has-session -t delta 2>/dev/null; then
  osascript -e 'display dialog "Delta tmux session 已存在 ✨\n\n雙擊「監看 Delta」連到既有 session" buttons {"OK"} default button "OK" with icon note'
else
  tmux new-session -d -s delta "claude"
  osascript -e 'display dialog "Delta agent 已背景啟動 ✨\n\n雙擊「監看 Delta」連看 claude UI\n首次連看會跳 trust folder 對話框，選 Yes 一次永久通行" buttons {"OK"} default button "OK" with icon note'
fi
INNER
chmod +x "$DESKTOP/啟動 Delta.command"

# ---- 2. 監看 Delta（開新 Terminal window attach tmux session） ----
cat > "$DESKTOP/監看 Delta.command" <<'INNER'
#!/bin/bash
osascript -e 'tell application "Terminal" to activate' -e 'tell application "Terminal" to do script "tmux attach -t delta 2>/dev/null || tmux new-session -s delta \"claude\""'
INNER
chmod +x "$DESKTOP/監看 Delta.command"

# ---- 3. MQTT 聊天.app（真 macOS .app bundle，雙擊跳 GUI 視窗） ----
APP="$DESKTOP/MQTT 聊天.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
mkdir -p "$APP/Contents/Resources"

cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>launcher</string>
  <key>CFBundleIdentifier</key>
  <string>com.alphamaid.PleiadeXMQTTGUI</string>
  <key>CFBundleName</key>
  <string>MQTT 聊天</string>
  <key>CFBundleDisplayName</key>
  <string>MQTT 聊天</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>1.0</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>LSMinimumSystemVersion</key>
  <string>13.0</string>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>LSUIElement</key>
  <false/>
</dict>
</plist>
EOF

cat > "$APP/Contents/MacOS/launcher" <<'INNER'
#!/bin/bash
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"
GUI_PY="$HOME/Library/CloudStorage/Dropbox/PleiadesMaids/MQTT/pleiadex_mqtt_gui.py"
if [ ! -f "$GUI_PY" ]; then
  mkdir -p "$(dirname "$GUI_PY")"
  curl -fL https://raw.githubusercontent.com/isisam/PleiadeXScripts/main/pleiadex_mqtt_gui.py -o "$GUI_PY"
fi
pip3 install --user --quiet --break-system-packages paho-mqtt 2>/dev/null || pip3 install --user --quiet paho-mqtt 2>/dev/null
exec /usr/bin/env python3 "$GUI_PY" --agent Delta --broker 192.168.1.200
INNER
chmod +x "$APP/Contents/MacOS/launcher"

# 清 xattr 與 adhoc sign（保險）
xattr -cr "$APP" 2>/dev/null || true
codesign --force --deep --sign - "$APP" 2>/dev/null || true

echo "✓ 桌面捷徑已建立："
ls -la "$DESKTOP/"*.command 2>/dev/null
ls -la "$DESKTOP/"*.app 2>/dev/null
echo
echo "Finder Desktop 雙擊即用："
echo "  • 啟動 Delta.command（背景 tmux session）"
echo "  • 監看 Delta.command（Terminal attach 看 Delta）"
echo "  • MQTT 聊天.app（雙擊跳 Tkinter GUI 視窗）"
