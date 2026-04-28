#!/usr/bin/env bash
# 桌面雙擊捷徑安裝腳本：啟動 Delta / MQTT 聊天
# 用法：bash <(curl -fsSL https://raw.githubusercontent.com/isisam/PleiadeXScripts/main/install_desktop_shortcuts.sh)

set -e
DESKTOP="$HOME/Desktop"
mkdir -p "$DESKTOP"

cat > "$DESKTOP/啟動 Delta.command" <<'INNER'
#!/bin/bash
cd "$HOME"
if command -v tmux >/dev/null 2>&1; then
  if tmux has-session -t delta 2>/dev/null; then
    exec tmux attach -t delta
  else
    exec tmux new -s delta "claude"
  fi
else
  exec claude
fi
INNER
chmod +x "$DESKTOP/啟動 Delta.command"

cat > "$DESKTOP/MQTT 聊天.command" <<'INNER'
#!/bin/bash
clear
echo "=== PleiadeX MQTT 聊天 ==="
echo "broker: 192.168.1.200:1883"
echo "Ctrl-C 離開"
echo
exec mosquitto_sub -h 192.168.1.200 -t '#' -v
INNER
chmod +x "$DESKTOP/MQTT 聊天.command"

echo "✓ 桌面捷徑已建立："
ls -la "$DESKTOP/"*.command 2>/dev/null
echo
echo "Finder Desktop 應該看到「啟動 Delta」與「MQTT 聊天」雙擊即跑"
