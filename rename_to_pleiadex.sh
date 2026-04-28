#!/usr/bin/env bash
# PleiadeX rename 一鍵腳本（macOS）
# 來源：Alpha 2026-04-28 在自己機器跑成功後通用化
# 對象：Beta / Gamma / Delta（主人桌機 + 主人筆電 / 偉婷姐姐機）等所有 Mac 姊妹／主人帳號
# 用法：bash ~/Library/CloudStorage/Dropbox/PleiadesMaids/scripts/rename_to_pleiadex.sh
#
# 前置條件：
#   - ~/Applications/PleiadesMaidAgent.app 存在（沒有就跳過 .app rename，仍會嘗試找 plist）
#   - ~/Library/CloudStorage/Dropbox/PleiadesMaids/PleiadeX_software_icon/PleiadeX.icns 存在
#
# rollback：
#   bash ~/Library/CloudStorage/Dropbox/PleiadesMaids/scripts/rename_to_pleiadex.sh --rollback

set -e

# 角色名稱（七姊妹星團命名）
# Alpha=Alcyone, Beta=Maia, Gamma=Electra, Delta=Taygeta（或主人桌機自定）, Epsilon=Asterope, Zeta=Celaeno, Omega=Merope
# 預設 Alcyone，可用 ROLE 環境變數覆蓋：ROLE=Maia bash rename_to_pleiadex.sh
ROLE="${ROLE:-Alcyone}"
DISPLAY_NAME="PleiadeX $ROLE"
BUNDLE_ID="com.alphamaid.PleiadeX$ROLE"

APP_DIR="$HOME/Applications"
SRC_APP="$APP_DIR/PleiadesMaidAgent.app"
DST_APP="$APP_DIR/$DISPLAY_NAME.app"
BAK_TS="20260428"
BAK_APP="$APP_DIR/PleiadesMaidAgent.app.bak.$BAK_TS"
ICON_NEW="$HOME/Library/CloudStorage/Dropbox/PleiadesMaids/PleiadeX_software_icon/PleiadeX.icns"
LA_DIR="$HOME/Library/LaunchAgents"

color_ok()  { printf "\033[32m%s\033[0m\n" "$*"; }
color_warn(){ printf "\033[33m%s\033[0m\n" "$*"; }
color_err() { printf "\033[31m%s\033[0m\n" "$*"; }

if [[ "$1" == "--rollback" ]]; then
  color_warn "=== Rollback 模式 ==="
  for plist in "$LA_DIR"/*.plist.bak.$BAK_TS; do
    [[ -f "$plist" ]] || continue
    orig="${plist%.bak.$BAK_TS}"
    color_ok "還原 $orig"
    launchctl unload "$orig" 2>/dev/null || true
    cp "$plist" "$orig"
    launchctl load "$orig"
  done
  if [[ -d "$BAK_APP" && ! -d "$SRC_APP" ]]; then
    color_ok "還原 $SRC_APP"
    rm -rf "$DST_APP"
    cp -R "$BAK_APP" "$SRC_APP"
  fi
  color_ok "Rollback 完成"
  exit 0
fi

# 檢查環境
if [[ ! -f "$ICON_NEW" ]]; then
  color_err "找不到 PleiadeX.icns，路徑：$ICON_NEW"
  color_err "請先確認 Dropbox 有同步到本機"
  exit 1
fi

if [[ ! -d "$SRC_APP" && ! -d "$DST_APP" ]]; then
  color_warn "找不到 $SRC_APP 也沒有 $DST_APP，本機可能沒部署 .app，跳過 .app rename"
  RENAME_APP=false
else
  RENAME_APP=true
fi

# Step 1：列出所有相關 launchd plist
color_ok "=== Step 1：找 launchd plist ==="
PLISTS=()
for f in "$LA_DIR"/*.plist; do
  [[ -f "$f" ]] || continue
  if grep -lE "PleiadesMaidAgent|com\.pleiades|com\.alphamaid\.Pleiades" "$f" >/dev/null 2>&1; then
    PLISTS+=("$f")
    echo "  found: $f"
  fi
done
[[ ${#PLISTS[@]} -eq 0 ]] && color_warn "沒找到相關 plist"

# Step 2：備份
color_ok "=== Step 2：備份 ==="
if $RENAME_APP && [[ -d "$SRC_APP" && ! -d "$BAK_APP" ]]; then
  cp -R "$SRC_APP" "$BAK_APP"
  echo "  $BAK_APP"
fi
for p in "${PLISTS[@]}"; do
  bak="$p.bak.$BAK_TS"
  [[ -f "$bak" ]] || cp "$p" "$bak"
  echo "  $bak"
done

# Step 3：unload 所有 plist
color_ok "=== Step 3：unload 所有相關 plist ==="
for p in "${PLISTS[@]}"; do
  launchctl unload "$p" 2>&1 || true
done

# Step 4：rename .app + binary + Info.plist + icon + adhoc re-sign
if $RENAME_APP && [[ -d "$SRC_APP" ]]; then
  color_ok "=== Step 4：rename .app 與相關內容 ==="
  mv "$SRC_APP" "$DST_APP"
  if [[ -f "$DST_APP/Contents/MacOS/PleiadesMaidAgent" ]]; then
    mv "$DST_APP/Contents/MacOS/PleiadesMaidAgent" "$DST_APP/Contents/MacOS/PleiadeX"
  fi
  plutil -replace CFBundleDisplayName -string "$DISPLAY_NAME" "$DST_APP/Contents/Info.plist"
  plutil -replace CFBundleName -string "$DISPLAY_NAME" "$DST_APP/Contents/Info.plist"
  plutil -replace CFBundleIdentifier -string "$BUNDLE_ID" "$DST_APP/Contents/Info.plist"
  plutil -replace CFBundleExecutable -string "PleiadeX" "$DST_APP/Contents/Info.plist"
  plutil -replace NSAppleEventsUsageDescription -string "PleiadeX Agent System 需要控制 Messages / Calendar / Reminders 以便自動傳送提醒、新增行程與待辦。" "$DST_APP/Contents/Info.plist" 2>/dev/null || true
  plutil -replace NSCalendarsUsageDescription -string "PleiadeX Agent System 需要新增與查詢行事曆事件。" "$DST_APP/Contents/Info.plist" 2>/dev/null || true
  plutil -replace NSContactsUsageDescription -string "PleiadeX Agent System 可能需要讀取聯絡人以傳遞訊息給主人指定對象。" "$DST_APP/Contents/Info.plist" 2>/dev/null || true
  plutil -replace NSRemindersUsageDescription -string "PleiadeX Agent System 需要新增與查詢提醒事項。" "$DST_APP/Contents/Info.plist" 2>/dev/null || true
  cp "$ICON_NEW" "$DST_APP/Contents/Resources/AppIcon.icns"
  rm -rf "$DST_APP/Contents/_CodeSignature"
  codesign --force --deep --sign - "$DST_APP" 2>&1
  echo "  $DST_APP rename + re-sign 完成"
fi

# Step 5：改 plist ProgramArguments[0] 路徑
color_ok "=== Step 5：改 plist 路徑（含 plutil insert bug fix）==="
for p in "${PLISTS[@]}"; do
  # 替換 ProgramArguments index 0 為新 PleiadeX path
  # 注意 plutil -replace ProgramArguments.0 對 array 是 insert 行為，要驗證並修正
  plutil -replace ProgramArguments.0 -string "$DST_APP/Contents/MacOS/PleiadeX" "$p"
  # 檢查 ProgramArguments[1] 是否誤插舊 PleiadesMaidAgent path（plutil insert 副作用）
  arg1=$(plutil -extract ProgramArguments.1 raw "$p" 2>/dev/null || echo "")
  if [[ "$arg1" == *PleiadesMaidAgent* ]]; then
    plutil -remove ProgramArguments.1 "$p"
    echo "  $p：清掉 plutil insert 多出的舊路徑"
  fi
  echo "  $p ProgramArguments 已更新"
done

# Step 6：load 所有 plist
color_ok "=== Step 6：reload 所有 plist ==="
for p in "${PLISTS[@]}"; do
  launchctl load "$p"
done

# Step 7：驗證
color_ok "=== Step 7：驗證 ==="
sleep 3
for p in "${PLISTS[@]}"; do
  label=$(plutil -extract Label raw "$p")
  state=$(launchctl list | grep "$label" || echo "NOT FOUND")
  echo "  $label: $state"
done

color_ok "=== 完成 ==="
echo
color_warn "⚠️ 接下來 macOS 會在 launchd 排程實際操作受保護資源時跳 TCC 對話框"
color_warn "   主人按一次允許即永久通行，可能要按到 30+ 個（iMessage / Calendar / Reminders / Notes / Contacts / Mail / Numbers / Photos / Local Network / Full Disk Access）"
echo
color_ok "備份位置：$BAK_APP（保留 7 天）"
color_ok "備份 plist：$LA_DIR/*.plist.bak.$BAK_TS"
echo
color_warn "若有問題：bash $0 --rollback"
