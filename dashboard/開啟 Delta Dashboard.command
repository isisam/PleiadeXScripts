#!/bin/bash
# Delta Dashboard 雙擊啟動器（自動補裝 paho-mqtt 1.6.1 相容版）
#
# 為什麼鎖 1.6.1：paho-mqtt 2.x binary wheel 編譯時依賴新版 macOS framework
# （macOS 26+），舊版 macOS 跑會 abort。1.6.1 純 Python，全平台通吃。

DASH_DIR="$(dirname "$0")"
if [ ! -f "$DASH_DIR/delta_dashboard.py" ]; then
    FOUND=""
    for d in "$HOME/Library/CloudStorage/Dropbox/PleiadesMaids/MQTT/dashboard" \
             "$HOME/Dropbox/PleiadesMaids/MQTT/dashboard"; do
        if [ -f "$d/delta_dashboard.py" ]; then
            FOUND="$d"
            break
        fi
    done
    if [ -z "$FOUND" ]; then
        echo "❌ 找不到 delta_dashboard.py，已嘗試 $DASH_DIR 與 \$HOME/.../Dropbox/.../MQTT/dashboard/。"
        echo "排錯：Dropbox 同步是否完成（離線可用，檔案 ≥ 35KB）。"
        read -p "按 Enter 關閉..."
        exit 2
    fi
    DASH_DIR="$FOUND"
fi
cd "$DASH_DIR" || { echo "cd 失敗：$DASH_DIR"; read -p "按 Enter 關閉..."; exit 2; }

# 用 Python.app 內的 binary（不是 /usr/local/bin/python3.13）
# 原因：python.org 的 CLI binary 簽名 ID 是 "python3"，跟系統 Python 撞名，
# macOS 26 Local Network 隱私框架認不出新的 TeamID，會 silently EHOSTUNREACH。
# Python.app 內的 binary 簽名 ID 是 "org.python.python"，有獨立隱私紀錄、可連 LAN broker。
PYTHON=/Library/Frameworks/Python.framework/Versions/3.13/Resources/Python.app/Contents/MacOS/Python
REQUIRED="paho-mqtt==1.6.1"

# 檢查 paho-mqtt 1.6.x 是否已裝
NEEDS_INSTALL=true
if "$PYTHON" -c "import paho.mqtt.client as c; v=c.MQTTv31; import paho; assert paho.mqtt.__version__.startswith('1.6')" 2>/dev/null; then
    NEEDS_INSTALL=false
fi

if [ "$NEEDS_INSTALL" = true ]; then
    echo "首次執行（或版本不對）：清掉舊版 + 安裝 paho-mqtt 1.6.1..."
    "$PYTHON" -m pip uninstall -y paho-mqtt 2>/dev/null
    "$PYTHON" -m pip install --user "$REQUIRED"
    if [ $? -ne 0 ]; then
        echo ""
        echo "❌ 套件安裝失敗。請主人 iMessage 通知 Alpha 處理。"
        echo "   錯誤訊息可能在上面，或執行： $PYTHON -m pip install --user $REQUIRED"
        read -p "按 Enter 關閉..."
        exit 1
    fi
fi

exec "$PYTHON" "$DASH_DIR/delta_dashboard.py"
