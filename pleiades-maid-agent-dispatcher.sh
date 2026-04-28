#!/bin/bash
# 昴宿女僕代理 — 統一排程派發器
# launchd plist 會以本 binary 為 Program，責任簽章為本 .app
# 用法：PleiadesMaidAgent <任務名> [額外參數]

set -eo pipefail

LOG_DIR="/tmp"
TASK="${1:-}"
shift || true
LOG="$LOG_DIR/maid-agent.log"
STATUS_FILE="$LOG_DIR/maid-agent-last.json"

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') [${TASK:-noop}] $*" >> "$LOG"; }

write_status() {
  printf '{"ts":"%s","task":"%s","ok":%s,"reason":"%s"}\n' \
    "$(date '+%Y-%m-%dT%H:%M:%S%z')" "${TASK:-noop}" "$1" "$2" > "$STATUS_FILE"
}

fail() { log "FAIL: $1"; write_status false "$1"; exit 1; }

# PATH 基本保障（launchd 預設 PATH 很小）
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"
export LANG=en_US.UTF-8

SCRIPTS_DIR="/Users/Alpha/.claude"

log "INFO: 開始派發"

case "$TASK" in
  dashboard-refresh)
    bash "$SCRIPTS_DIR/dashboard-refresh.sh" "$@" || fail "dashboard-refresh 失敗"
    ;;
  dashboard-refresh-verifier)
    bash "$SCRIPTS_DIR/dashboard-refresh-verifier.sh" "$@" || fail "verifier 失敗"
    ;;
  memory-organize)
    bash "$SCRIPTS_DIR/memory-organize.sh" "$@" || fail "memory-organize 失敗"
    ;;
  memory-organize-verifier)
    bash "$SCRIPTS_DIR/memory-organize-verifier.sh" "$@" || fail "memory-organize-verifier 失敗"
    ;;
  reminder-check)
    bash "$SCRIPTS_DIR/reminder-check.sh" "$@" || fail "reminder-check 失敗"
    ;;
  daily-clear)
    bash "$SCRIPTS_DIR/daily-clear.sh" "$@" || fail "daily-clear 失敗"
    ;;
  maid-watchdog)
    bash "$SCRIPTS_DIR/maid-watchdog.sh" "$@" || fail "maid-watchdog 失敗"
    ;;
  m017-nightly-merge)
    bash "$SCRIPTS_DIR/m017-nightly-merge.sh" "$@" || fail "m017-nightly-merge 失敗"
    ;;
  m017-verify-merge)
    bash "$SCRIPTS_DIR/m017-verify-merge.sh" "$@" || fail "m017-verify-merge 失敗"
    ;;
  m017-archive-inbox)
    bash "$SCRIPTS_DIR/m017-archive-inbox.sh" "$@" || fail "m017-archive-inbox 失敗"
    ;;
  one-shot)
    # 一次性任務：直接執行 $1 指定的完整 script 路徑
    one_script="${1:-}"
    shift || true
    [ -n "$one_script" ] && [ -f "$one_script" ] || fail "one-shot 需要提供可執行 script 路徑"
    bash "$one_script" "$@" || fail "one-shot ($one_script) 失敗"
    ;;
  send-imessage)
    # 傳 iMessage 給主人：PleiadesMaidAgent send-imessage "內容"
    text="${1:-}"
    [ -n "$text" ] || fail "send-imessage 需要文字內容"
    osascript -e "tell application \"Messages\" to send \"$text\" to buddy \"isisam@mac.com\" of (1st service whose service type = iMessage)" >> "$LOG" 2>&1 || fail "osascript send 失敗"
    ;;
  tcc-bootstrap)
    # 一次性：觸發所有可能 TCC 對話框，主人按完一次永久通行
    log "INFO: tcc-bootstrap chain 開始"
    osascript -e 'tell application "Reminders"     to count of lists'                       >/dev/null 2>&1 || true
    osascript -e 'tell application "Calendar"      to count of calendars'                   >/dev/null 2>&1 || true
    osascript -e 'tell application "Notes"         to count of notes'                       >/dev/null 2>&1 || true
    osascript -e 'tell application "Contacts"      to count of every person'                >/dev/null 2>&1 || true
    osascript -e 'tell application "Messages"      to count of chats'                       >/dev/null 2>&1 || true
    osascript -e 'tell application "Mail"          to count of mailboxes'                   >/dev/null 2>&1 || true
    osascript -e 'tell application "Numbers"       to count of documents'                   >/dev/null 2>&1 || true
    osascript -e 'tell application "Pages"         to count of documents'                   >/dev/null 2>&1 || true
    osascript -e 'tell application "Keynote"       to count of documents'                   >/dev/null 2>&1 || true
    osascript -e 'tell application "Photos"        to count of albums'                      >/dev/null 2>&1 || true
    osascript -e 'tell application "Music"         to count of tracks'                      >/dev/null 2>&1 || true
    osascript -e 'tell application "Safari"        to count of windows'                     >/dev/null 2>&1 || true
    osascript -e 'tell application "Finder"        to count of items in (path to desktop folder)' >/dev/null 2>&1 || true
    osascript -e 'tell application "System Events" to count of processes'                   >/dev/null 2>&1 || true
    osascript -e 'tell application "Google Chrome"  to count of windows'                    >/dev/null 2>&1 || true
    osascript -e 'tell application "Brave Browser"  to count of windows'                    >/dev/null 2>&1 || true
    osascript -e 'tell application "Firefox"        to count of windows'                    >/dev/null 2>&1 || true
    osascript -e 'tell application "Microsoft Edge" to count of windows'                    >/dev/null 2>&1 || true
    osascript -e 'tell application "Slack"          to count of unread messages'            >/dev/null 2>&1 || true
    osascript -e 'tell application "Spotify"        to count of tracks'                     >/dev/null 2>&1 || true
    osascript -e 'tell application "Terminal"       to count of windows'                    >/dev/null 2>&1 || true
    osascript -e 'tell application "iTerm"          to count of windows'                    >/dev/null 2>&1 || true
    ls "$HOME/Documents"               >/dev/null 2>&1 || true
    ls "$HOME/Desktop"                 >/dev/null 2>&1 || true
    ls "$HOME/Downloads"               >/dev/null 2>&1 || true
    ls "$HOME/Movies"                  >/dev/null 2>&1 || true
    ls "$HOME/Pictures"                >/dev/null 2>&1 || true
    ls "$HOME/Music"                   >/dev/null 2>&1 || true
    ls "$HOME/Library/Mobile Documents" >/dev/null 2>&1 || true
    ping -c 1 -t 1 192.168.1.200       >/dev/null 2>&1 || true
    ping -c 1 -t 1 192.168.1.1         >/dev/null 2>&1 || true
    osascript -e 'tell application "System Events" to keystroke ""' >/dev/null 2>&1 || true
    log "INFO: tcc-bootstrap chain 結束"
    ;;
  noop|"")
    log "INFO: noop（測試用）"
    ;;
  *)
    fail "未知任務：$TASK"
    ;;
esac

log "INFO: 派發完成"
write_status true "task=$TASK ok"
