#!/usr/bin/env bash
# 桌面雙擊捷徑安裝（v2，三個 .command）
# 用法：bash <(curl -fsSL https://raw.githubusercontent.com/isisam/PleiadeXScripts/main/install_desktop_shortcuts.sh)

set -e
DESKTOP="$HOME/Desktop"
mkdir -p "$DESKTOP"
CHAT="$HOME/Library/CloudStorage/Dropbox/PleiadesMaids/MQTT/pleiadex_mqtt_chat.py"

# ---- 1. 啟動 Delta（背景建 tmux session） ----
cat > "$DESKTOP/啟動 Delta.command" <<'INNER'
#!/bin/bash
cd "$HOME"
if command -v tmux >/dev/null 2>&1; then
  if tmux has-session -t delta 2>/dev/null; then
    osascript -e 'display notification "Delta tmux session 已存在（不重開）" with title "PleiadeX Delta"'
  else
    tmux new-session -d -s delta "claude"
    osascript -e 'display notification "Delta agent 已背景啟動（tmux session: delta）" with title "PleiadeX Delta"'
  fi
else
  osascript -e 'display alert "需先 brew install tmux" message "桌機沒 tmux，請開 Terminal 跑 brew install tmux"'
fi
INNER
chmod +x "$DESKTOP/啟動 Delta.command"

# ---- 2. 監看 Delta（開新 Terminal window attach tmux session） ----
cat > "$DESKTOP/監看 Delta.command" <<'INNER'
#!/bin/bash
osascript -e 'tell application "Terminal" to activate' -e 'tell application "Terminal" to do script "tmux attach -t delta 2>/dev/null || tmux new-session -s delta \"claude\""'
INNER
chmod +x "$DESKTOP/監看 Delta.command"

# ---- 3. MQTT 聊天 GUI（開新 Terminal window 跑 pleiadex_mqtt_chat.py） ----
cat > "$DESKTOP/MQTT 聊天.command" <<INNER
#!/bin/bash
CHAT_PY="$CHAT"
if [ ! -f "\$CHAT_PY" ]; then
  mkdir -p "\$(dirname \$CHAT_PY)"
  curl -fL https://raw.githubusercontent.com/isisam/PleiadeXScripts/main/pleiadex_mqtt_chat.py -o "\$CHAT_PY"
fi
osascript -e 'tell application "Terminal" to activate' -e "tell application \"Terminal\" to do script \"python3 \$CHAT_PY --agent Delta --broker 192.168.1.200\""
INNER
chmod +x "$DESKTOP/MQTT 聊天.command"

echo "✓ 三個桌面捷徑已建立："
ls -la "$DESKTOP/"*.command 2>/dev/null
echo
echo "Finder Desktop 雙擊即用："
echo "  • 啟動 Delta（背景 tmux session）"
echo "  • 監看 Delta（Terminal attach 看 Delta）"
echo "  • MQTT 聊天（Terminal 跑 chat client）"
