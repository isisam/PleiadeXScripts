#!/usr/bin/env bash
# PleiadeX 全新部署腳本（macOS）
# 用途：本機沒有 PleiadesMaidAgent.app／PleiadeX.app，從 Dropbox template 部署一份
# 對象：桌機 Delta、主人筆電、新加入姊妹機器
# 用法：bash ~/Library/CloudStorage/Dropbox/PleiadesMaids/scripts/deploy_pleiadex.sh
#
# 行為：
#   1. cp Dropbox/PleiadeX_app_template/PleiadeX.app 到 ~/Applications/
#   2. 重新 codesign adhoc（避免 quarantine）
#   3. 寫 watchdog plist（如果沒有）
#   4. launchctl load
#   5. TCC 對話框會跳，主人按

set -e

APP_DIR="$HOME/Applications"
DST_APP="$APP_DIR/PleiadeX.app"
TEMPLATE="$HOME/Library/CloudStorage/Dropbox/PleiadesMaids/PleiadeX_app_template/PleiadeX.app"
LA_DIR="$HOME/Library/LaunchAgents"
LABEL="com.alpha.maid-watchdog"
PLIST="$LA_DIR/$LABEL.plist"

color_ok()  { printf "\033[32m%s\033[0m\n" "$*"; }
color_warn(){ printf "\033[33m%s\033[0m\n" "$*"; }
color_err() { printf "\033[31m%s\033[0m\n" "$*"; }

# 檢查 template
if [[ ! -d "$TEMPLATE" ]]; then
  color_err "找不到 template：$TEMPLATE"
  color_err "確認 Dropbox 已同步到本機"
  exit 1
fi

# 檢查目標已存在
if [[ -d "$DST_APP" ]]; then
  color_warn "$DST_APP 已存在，請先用 rename_to_pleiadex.sh 處理現有 .app；或手動移除"
  exit 1
fi

# Step 1：cp template
color_ok "=== Step 1：複製 template 到 $DST_APP ==="
mkdir -p "$APP_DIR"
cp -R "$TEMPLATE" "$DST_APP"

# Step 2：清所有 xattr + 重 sign（adhoc）
color_ok "=== Step 2：清 xattr + adhoc re-sign ==="
# xattr -cr 清除所有 extended attributes（含 com.dropbox.attrs／com.apple.quarantine／resource fork）
# 必須清完整才能 codesign，否則 macOS 拒絕「resource fork, Finder information, or similar detritus not allowed」
xattr -cr "$DST_APP" 2>/dev/null || true
rm -rf "$DST_APP/Contents/_CodeSignature"
codesign --force --deep --sign - "$DST_APP" 2>&1
codesign -dv "$DST_APP" 2>&1 | head -3

# Step 3：寫 watchdog plist（如果沒有）
color_ok "=== Step 3：寫 watchdog plist ==="
mkdir -p "$LA_DIR"
if [[ -f "$PLIST" ]]; then
  color_warn "  $PLIST 已存在，備份再覆寫"
  cp "$PLIST" "$PLIST.bak.20260428"
  launchctl unload "$PLIST" 2>/dev/null || true
fi
cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>$DST_APP/Contents/MacOS/PleiadeX</string>
        <string>maid-watchdog</string>
    </array>
    <key>StartInterval</key>
    <integer>30</integer>
    <key>RunAtLoad</key>
    <true/>
    <key>StandardOutPath</key>
    <string>/tmp/maid-watchdog.log</string>
    <key>StandardErrorPath</key>
    <string>/tmp/maid-watchdog-error.log</string>
</dict>
</plist>
EOF
echo "  $PLIST 已寫"

# Step 4：load
color_ok "=== Step 4：launchctl load ==="
launchctl load "$PLIST"
sleep 3
state=$(launchctl list | grep "$LABEL" || echo "NOT FOUND")
echo "  $LABEL: $state"

color_ok "=== 部署完成 ==="
echo
color_warn "⚠️ macOS 在 launchd 排程實操受保護資源時跳 TCC 對話框，主人按一次允許即永久通行"
echo
color_ok "rollback：launchctl unload $PLIST && rm -rf $DST_APP"
