#!/usr/bin/env bash
# 桌機 Delta Dashboard 安裝（主人 4/27 04:04 規格 4-tab GUI）
# 用法：bash <(curl -fsSL https://raw.githubusercontent.com/isisam/PleiadeXScripts/main/install_dashboard.sh)

set -e

REPO_RAW="https://raw.githubusercontent.com/isisam/PleiadeXScripts/main/dashboard"
DASH_DIR="$HOME/Library/CloudStorage/Dropbox/PleiadesMaids/MQTT/dashboard"
DESKTOP="$HOME/Desktop"

color_ok()  { printf "\033[32m%s\033[0m\n" "$*"; }
color_warn(){ printf "\033[33m%s\033[0m\n" "$*"; }

color_ok "=== Step 1: 下載 dashboard 檔案 ==="
mkdir -p "$DASH_DIR"
curl -fsSL "$REPO_RAW/delta_dashboard.py"     -o "$DASH_DIR/delta_dashboard.py"
curl -fsSL "$REPO_RAW/PleiadexDashboard.icns" -o "$DASH_DIR/PleiadexDashboard.icns"
# 中文檔名 URL encode
curl -fsSL "$REPO_RAW/%E9%96%8B%E5%95%9F%20Delta%20Dashboard.command" -o "$DASH_DIR/開啟 Delta Dashboard.command"
chmod +x "$DASH_DIR/開啟 Delta Dashboard.command"
ls -la "$DASH_DIR/" | grep -E "delta_dashboard|Dashboard"

color_ok "=== Step 2: 桌面捷徑 ==="
cp "$DASH_DIR/開啟 Delta Dashboard.command" "$DESKTOP/開啟 Delta Dashboard.command"
chmod +x "$DESKTOP/開啟 Delta Dashboard.command"

color_ok "=== Step 3: 確認 Python.framework 3.13（macOS 26 LAN privacy 必要）==="
PYTHON=/Library/Frameworks/Python.framework/Versions/3.13/Resources/Python.app/Contents/MacOS/Python
if [[ ! -x "$PYTHON" ]]; then
  color_warn "找不到 $PYTHON"
  color_warn "請從 python.org 裝 Python 3.13：https://www.python.org/downloads/"
  exit 1
fi

color_ok "=== Step 4: 裝 paho-mqtt 1.6.1（鎖版避 macOS 26 abort）==="
"$PYTHON" -m pip install --user "paho-mqtt==1.6.1" 2>&1 | tail -3

color_ok "=== 完成 ==="
echo
color_warn "雙擊 ~/Desktop/開啟 Delta Dashboard.command 即啟 4-tab GUI"
echo "  Tab 1 聊天頁 / Tab 2 系統 / Tab 3 日課表 / Tab 4 指令"
echo
color_warn "新訂閱：pleiadex/agents/Xeon/outbox（主人廣播）+ pleiadex/agents/+/inbox（看誰傳給誰）"
