#!/bin/bash
# 昴宿七姊妹 — 卡住自動恢復 watchdog
# 也負責偵測主人的 @Alpha /clear 與 @All /clear 指令

echo "$(date '+%Y-%m-%d %H:%M:%S') watchdog tick" >> /tmp/maid-watchdog-heartbeat.log

HEARTBEAT_DIR="/tmp/maid-heartbeat"
WAITING_TIMEOUT=60
STUCK_TIMEOUT=600
DB="$HOME/Library/Messages/chat.db"
MASTER="isisam@mac.com"
MASTER_PHONE="+886978133208"
STATE_DIR="$HOME/.claude/watchdog-state"
LAST_ROWID_FILE="$STATE_DIR/imessage-clear-last-rowid"
SESSION_MISSING_FILE="$STATE_DIR/alpha-session-missing-ts"
SESSION_RESTART_COOLDOWN=300  # 兩次自動重啟最少間隔（秒）
TMUX_BIN="/opt/homebrew/bin/tmux"
ALPHA_SESSION="claude-imessage"
ALPHA_RESTART_SCRIPT="/Users/Alpha/claude-imessage.sh"
GAMMA_SOCKET="/tmp/tmux-gamma"
GAMMA_SESSION="gamma-imessage"

mkdir -p "$STATE_DIR"

send_owner_message() {
  local msg="$1"
  osascript -e "tell application \"Messages\" to send \"$msg\" to buddy \"$MASTER\" of (service 1 whose service type is iMessage)" 2>/dev/null
}

_tmux_has_session() {
  local socket="$1"
  local session="$2"
  if [ -n "$socket" ]; then
    "$TMUX_BIN" -S "$socket" has-session -t "$session" 2>/dev/null
  else
    "$TMUX_BIN" has-session -t "$session" 2>/dev/null
  fi
}

_tmux_send() {
  local socket="$1"
  local session="$2"
  shift 2
  if [ -n "$socket" ]; then
    "$TMUX_BIN" -S "$socket" send-keys -t "$session" "$@"
  else
    "$TMUX_BIN" send-keys -t "$session" "$@"
  fi
}

clear_session() {
  local display_name="$1"
  local socket="$2"
  local session="$3"

  if _tmux_has_session "$socket" "$session"; then
    _tmux_send "$socket" "$session" Escape
    sleep 1
    _tmux_send "$socket" "$session" "/clear" Enter
    return 0
  fi
  return 1
}

# 取得 Alpha 當前 context 使用率（百分比 0-100）
# 讀 ~/.claude/projects/-Users-Alpha 內最新 jsonl 的最後一個 usage
get_alpha_context_pct() {
  local proj_dir="$HOME/.claude/projects/-Users-Alpha"
  local latest
  latest=$(ls -t "$proj_dir"/*.jsonl 2>/dev/null | head -1)
  if [ -z "$latest" ]; then
    echo 0
    return
  fi

  /usr/bin/python3 - "$latest" 2>/dev/null <<'PY' || echo 0
import json, sys
path = sys.argv[1]
last_usage = None
try:
    with open(path, 'r', errors='ignore') as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                obj = json.loads(line)
            except Exception:
                continue
            msg = obj.get('message') if isinstance(obj, dict) else None
            if isinstance(msg, dict) and isinstance(msg.get('usage'), dict):
                last_usage = msg['usage']
except Exception:
    print(0); sys.exit()
if not last_usage:
    print(0); sys.exit()
total = (last_usage.get('input_tokens') or 0) + \
        (last_usage.get('cache_read_input_tokens') or 0) + \
        (last_usage.get('cache_creation_input_tokens') or 0)
pct = int(total * 100 / 200000)
print(pct)
PY
}

process_clear_commands() {
  [ -f "$DB" ] || { echo "$(date '+%Y-%m-%d %H:%M:%S') DEBUG: chat.db 不存在" >> /tmp/maid-watchdog-debug.log; return 0; }

  local last_rowid=0
  if [ -f "$LAST_ROWID_FILE" ]; then
    last_rowid=$(cat "$LAST_ROWID_FILE" 2>/dev/null)
  fi
  echo "$(date '+%Y-%m-%d %H:%M:%S') DEBUG: last_rowid=$last_rowid" >> /tmp/maid-watchdog-debug.log

  if ! [[ "$last_rowid" =~ ^[0-9]+$ ]]; then
    last_rowid=0
  fi

  if [ "$last_rowid" -eq 0 ]; then
    last_rowid=$(sqlite3 "$DB" "SELECT IFNULL(MAX(ROWID),0) FROM message;" 2>/dev/null)
    echo "${last_rowid:-0}" > "$LAST_ROWID_FILE"
    return
  fi

  local rows
  rows=$(sqlite3 -tabs "$DB" "
    SELECT m.ROWID, m.text
    FROM message m
    LEFT JOIN handle h ON m.handle_id = h.ROWID
    WHERE m.ROWID > $last_rowid
      AND m.is_from_me = 0
      AND m.text IS NOT NULL
      AND (LOWER(h.id) = LOWER('$MASTER') OR h.id = '$MASTER_PHONE')
    ORDER BY m.ROWID ASC;
  " 2>/dev/null)

  [ -n "$rows" ] || return 0

  local max_rowid="$last_rowid"
  local any_triggered=0

  while IFS=$'\t' read -r rowid text; do
    [ -n "$rowid" ] || continue
    max_rowid="$rowid"

    local lower
    lower=$(printf '%s' "$text" | tr '[:upper:]' '[:lower:]')

    if printf '%s' "$lower" | grep -Eq '@all[[:space:]]*/?clear([[:space:]]|$)'; then
      local cleared=()
      local failed=()

      if clear_session "Alpha" "" "$ALPHA_SESSION"; then
        cleared+=("Alpha")
      else
        failed+=("Alpha")
      fi

      if clear_session "Gamma" "$GAMMA_SOCKET" "$GAMMA_SESSION"; then
        cleared+=("Gamma")
      else
        failed+=("Gamma")
      fi

      local msg="🧹 已收到 @All /clear"
      if [ ${#cleared[@]} -gt 0 ]; then
        msg+="，已清空：${cleared[*]}"
      fi
      if [ ${#failed[@]} -gt 0 ]; then
        msg+="，未找到 session：${failed[*]}"
      fi
      send_owner_message "$msg"
      any_triggered=1
      continue
    fi

    if printf '%s' "$lower" | grep -Eq '@alpha[[:space:]]*/?clear([[:space:]]|$)'; then
      if clear_session "Alpha" "" "$ALPHA_SESSION"; then
        send_owner_message "🧹 已收到 @Alpha /clear，Alpha 上下文已清空"
      else
        send_owner_message "⚠️ 已收到 @Alpha /clear，但找不到 Alpha session"
      fi
      any_triggered=1
      continue
    fi

    if printf '%s' "$lower" | grep -Eq '@gamma[[:space:]]*/?clear([[:space:]]|$)'; then
      if clear_session "Gamma" "$GAMMA_SOCKET" "$GAMMA_SESSION"; then
        send_owner_message "🧹 已收到 @Gamma /clear，Gamma 上下文已清空"
      else
        send_owner_message "⚠️ 已收到 @Gamma /clear，但找不到 Gamma session"
      fi
      any_triggered=1
      continue
    fi

    # /cc 救援指令（主人專屬）
    if printf '%s' "$lower" | grep -Eq '^/cc([[:space:]]|$)'; then
      local cc_cmd
      cc_cmd=$(printf '%s' "$lower" | sed 's|^/cc[[:space:]]*||')
      /Users/Alpha/.claude/cc-handler.sh "$cc_cmd" &
      any_triggered=1
      continue
    fi

    # @All 午休並清理記憶 / @All 睡覺並清理記憶 → 檢查 Alpha context >20% 才清
    if printf '%s' "$text" | grep -Eq '@[Aa]ll[[:space:]]*(午休|睡覺)並清理記憶'; then
      local mode="午休"
      if printf '%s' "$text" | grep -q '睡覺'; then
        mode="睡覺"
      fi
      local pct
      pct=$(get_alpha_context_pct)
      [[ "$pct" =~ ^[0-9]+$ ]] || pct=0
      if [ "$pct" -gt 20 ]; then
        if clear_session "Alpha" "" "$ALPHA_SESSION"; then
          send_owner_message "💤 ${mode}：Alpha context ${pct}% > 20%，已清空～"
        else
          send_owner_message "⚠️ ${mode}：Alpha context ${pct}%，但找不到 Alpha session"
        fi
      else
        send_owner_message "💤 ${mode}：Alpha context ${pct}% ≤ 20%，無需清理"
      fi
      any_triggered=1
      continue
    fi
  done <<< "$rows"

  echo "$max_rowid" > "$LAST_ROWID_FILE"

  if [ "$any_triggered" -eq 1 ]; then
    sleep 1
  fi
}

check_and_rescue() {
  local name="$1"
  local session="$2"
  local socket="$3"
  local file="$HEARTBEAT_DIR/$name"

  [ -f "$file" ] || return 0

  local status=$(head -1 "$file" 2>/dev/null)
  local ts=$(sed -n '2p' "$file" 2>/dev/null)
  local now=$(date +%s)
  local age=$(( now - ${ts:-0} ))
  local display_name=$(echo "$name" | sed 's/.*/\u&/')

  if [ "$status" = "waiting" ] && [ "$age" -gt "$WAITING_TIMEOUT" ]; then
    if _tmux_has_session "$socket" "$session"; then
      _tmux_send "$socket" "$session" Escape
      sleep 1
      _tmux_send "$socket" "$session" Escape
      send_owner_message "⚠️ 女僕 ${display_name} 卡在確認提示超過 ${WAITING_TIMEOUT} 秒，已自動取消恢復。"
    fi
  elif [ "$status" = "responding" ] && [ "$age" -gt "$STUCK_TIMEOUT" ]; then
    if _tmux_has_session "$socket" "$session"; then
      _tmux_send "$socket" "$session" Escape
      sleep 1
      _tmux_send "$socket" "$session" Escape
      send_owner_message "⚠️ 女僕 ${display_name} 回應中卡住超過 ${STUCK_TIMEOUT} 秒，已自動取消恢復。"
    fi
  fi
}

# Alpha tmux session 存活檢查（掛了自動重啟，含 bun 孤兒清理 + cooldown + log）
RESTART_LOG="/tmp/maid-watchdog-restart.log"

ensure_alpha_session_alive() {
  # Alpha session 存在 → 檢查是否 401
  if _tmux_has_session "" "$ALPHA_SESSION"; then
    rm -f "$SESSION_MISSING_FILE" 2>/dev/null

    # 偵測 401 authentication error → 自動重啟（免費修復，不需要 /login 或 API Key）
    local screen
    screen=$($TMUX_BIN capture-pane -t "$ALPHA_SESSION" -p 2>/dev/null | tail -10)
    if echo "$screen" | grep -qi "authentication_error\|Please run /login\|Not logged in\|API Error: 401"; then
      echo "$(date '+%Y-%m-%d %H:%M:%S') ALERT: Alpha 401 偵測到，自動重啟修復" >> "$RESTART_LOG"
      send_owner_message "⚠️ Alpha 401 錯誤，watchdog 自動重啟修復中⋯⋯"

      # kill + 清 bun + 重建（新 session 會讀 .claude.json 的最新 token）
      $TMUX_BIN kill-session -t "$ALPHA_SESSION" 2>/dev/null
      pkill -u Alpha -f "bun.*plugin" 2>/dev/null
      sleep 2

      export PATH=/Users/Alpha/.bun/bin:/Users/Alpha/.local/bin:/opt/homebrew/bin:/usr/bin:/bin
      export BUN_INSTALL=/Users/Alpha/.bun
      cd /Users/Alpha
      $TMUX_BIN new-session -d -s "$ALPHA_SESSION" \
        '/Users/Alpha/.local/bin/claude --model opus --channels plugin:telegram@claude-plugins-official --channels plugin:imessage@claude-plugins-official --dangerously-skip-permissions 2>> /Users/Alpha/claude-imessage-error.log'
      sleep 8

      if _tmux_has_session "" "$ALPHA_SESSION"; then
        send_owner_message "🤖 Alpha 401 已自動修復（重啟 session）✅"
        echo "$(date '+%Y-%m-%d %H:%M:%S') INFO: Alpha 401 自動修復成功" >> "$RESTART_LOG"
      else
        send_owner_message "🚨 Alpha 401 修復失敗，請主人手動處理"
        echo "$(date '+%Y-%m-%d %H:%M:%S') ERROR: Alpha 401 修復失敗" >> "$RESTART_LOG"
      fi
      return 1
    fi

    return 0
  fi

  # session 不存在，檢查冷卻時間避免重覆重啟（最少間隔 300 秒）
  local now last since
  now=$(date +%s)
  last=0
  if [ -f "$SESSION_MISSING_FILE" ]; then
    last=$(cat "$SESSION_MISSING_FILE" 2>/dev/null)
    [[ "$last" =~ ^[0-9]+$ ]] || last=0
  fi
  since=$(( now - last ))

  if [ "$last" -gt 0 ] && [ "$since" -lt "$SESSION_RESTART_COOLDOWN" ]; then
    # 冷卻中，不動作
    return 1
  fi

  echo "$now" > "$SESSION_MISSING_FILE"
  echo "$(date '+%Y-%m-%d %H:%M:%S') ALERT: Alpha session 不存在，開始重啟" >> "$RESTART_LOG"

  # 1. 清掉 Alpha 帳號下所有殘留 bun plugin 孤兒（避免吃爆 CPU）
  local bun_killed
  bun_killed=$(pkill -u Alpha -f "bun.*plugin" 2>&1 && echo "有清除" || echo "無殘留")
  echo "$(date '+%Y-%m-%d %H:%M:%S') INFO: 清理 bun 孤兒: $bun_killed" >> "$RESTART_LOG"

  # 2. 通知主人
  send_owner_message "⚠️ Alpha session 掛了，watchdog 正在重啟（已清理舊 bun）⋯⋯"

  # 3. 直接用 tmux 快速重啟（不走 claude-imessage.sh 的 sleep 30 慢路徑）
  export PATH=/Users/Alpha/.bun/bin:/Users/Alpha/.local/bin:/opt/homebrew/bin:/usr/bin:/bin
  export BUN_INSTALL=/Users/Alpha/.bun
  cd /Users/Alpha
  $TMUX_BIN new-session -d -s "$ALPHA_SESSION" \
    '/Users/Alpha/.local/bin/claude --model opus --channels plugin:telegram@claude-plugins-official --channels plugin:imessage@claude-plugins-official --dangerously-skip-permissions 2>> /Users/Alpha/claude-imessage-error.log'
  sleep 8
  if _tmux_has_session "" "$ALPHA_SESSION"; then
    send_owner_message "🤖 Alpha 已自動重啟 ✅"
    echo "$(date '+%Y-%m-%d %H:%M:%S') INFO: Alpha 直接 tmux 重啟成功" >> "$RESTART_LOG"
  else
    # 快速重啟失敗，fallback 到完整啟動腳本
    echo "$(date '+%Y-%m-%d %H:%M:%S') WARNING: 快速重啟失敗，fallback 到啟動腳本" >> "$RESTART_LOG"
    nohup /bin/bash "$ALPHA_RESTART_SCRIPT" >/dev/null 2>&1 &
    echo "$(date '+%Y-%m-%d %H:%M:%S') INFO: 已觸發啟動腳本（背景）" >> "$RESTART_LOG"
  fi
  return 1
}

AUTO_CONFIRM_LOG="/tmp/maid-watchdog-autoconfirm.log"
AUTO_CONFIRM_STATE="$STATE_DIR/auto-confirm-last-screen-hash"

auto_confirm_prompt() {
  local name="$1"
  local socket="$2"
  local session="$3"

  if ! _tmux_has_session "$socket" "$session"; then
    return 0
  fi

  local screen
  if [ -n "$socket" ]; then
    screen=$("$TMUX_BIN" -S "$socket" capture-pane -t "$session" -p 2>/dev/null | tail -20)
  else
    screen=$("$TMUX_BIN" capture-pane -t "$session" -p 2>/dev/null | tail -20)
  fi

  echo "$screen" | grep -qE "Do you want to (make this edit|proceed|create)" || return 0
  echo "$screen" | grep -q "❯ 1\." || return 0

  if echo "$screen" | grep -qiE "rm -rf|rm /|launchctl unload|kill -9|sudo |git push --force|git reset --hard|--no-verify|chmod 777|dd if=|mkfs|shutdown|reboot|launchctl bootout"; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') [$name] SKIP: 偵測到危險字，不自動按" >> "$AUTO_CONFIRM_LOG"
    send_owner_message "⚠️ 女僕 $name 遇到危險確認 prompt，已暫停等主人處理"
    return 0
  fi

  local hash
  hash=$(echo "$screen" | shasum | awk '{print $1}')
  local last=""
  [ -f "$AUTO_CONFIRM_STATE" ] && last=$(cat "$AUTO_CONFIRM_STATE" 2>/dev/null)
  [ "$hash" = "$last" ] && return 0

  local prompt_line
  prompt_line=$(echo "$screen" | grep -E "Do you want to" | tail -1)
  _tmux_send "$socket" "$session" "2" Enter
  echo "$hash" > "$AUTO_CONFIRM_STATE"
  echo "$(date '+%Y-%m-%d %H:%M:%S') [$name] AUTO-CONFIRM: pressed 2 ($prompt_line)" >> "$AUTO_CONFIRM_LOG"
  send_owner_message "🤖 女僕 $name 自動按 2 通過：$(echo "$prompt_line" | head -c 80)"
}

process_clear_commands
ensure_alpha_session_alive
check_and_rescue "alpha" "$ALPHA_SESSION" ""
check_and_rescue "gamma" "$GAMMA_SESSION" "$GAMMA_SOCKET"
auto_confirm_prompt "Alpha" "" "$ALPHA_SESSION"
auto_confirm_prompt "Gamma" "$GAMMA_SOCKET" "$GAMMA_SESSION"

# PleiadeX MQTT client 自啟：本機 Alpha 沒在跑就拉起來（idempotent + flock 防多開）
PLEIADEX_HELPER="$HOME/Library/CloudStorage/Dropbox/PleiadesMaids/MQTT/lib/pleiadex_ensure_running.sh"
[ -x "$PLEIADEX_HELPER" ] && "$PLEIADEX_HELPER" Alpha 2>/dev/null
