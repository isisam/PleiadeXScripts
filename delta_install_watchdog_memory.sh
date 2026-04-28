#!/usr/bin/env bash
# Delta 桌機完整部署：watchdog + 共同記憶 + 個人記憶
# 用法：bash <(curl -fsSL https://raw.githubusercontent.com/isisam/PleiadeXScripts/main/delta_install_watchdog_memory.sh)
#
# 動作流程
#   1. ssh-keygen 產 deploy key
#   2. 印 public key + 暫停讓主人去 GitHub PleiadeXMemory repo Settings → Deploy keys 加 key（勾 write access）
#   3. git clone PleiadeXMemory 到 ~/Library/CloudStorage/Dropbox/PleiadesMaids/MaidMemory/
#   4. 拉 dispatcher.sh + maid-watchdog.sh 到 ~/.claude/，sudo 同步一份到 /Users/Alpha/.claude/（給 binary 找）
#   5. plist 改回 30 秒輪詢
#   6. reload watchdog
#   7. 寫 Delta 專屬 CLAUDE.md 框架（含 Shion Delta: 簽名規則）

set -e

REPO_RAW="https://raw.githubusercontent.com/isisam/PleiadeXScripts/main"
SSH_KEY="$HOME/.ssh/pleiadex_memory_delta"
MEM_DIR="$HOME/Library/CloudStorage/Dropbox/PleiadesMaids/MaidMemory"

color_ok()  { printf "\033[32m%s\033[0m\n" "$*"; }
color_warn(){ printf "\033[33m%s\033[0m\n" "$*"; }
color_err() { printf "\033[31m%s\033[0m\n" "$*"; }

# Step 1: ssh-keygen
color_ok "=== Step 1: 產 SSH deploy key ==="
mkdir -p ~/.ssh
chmod 700 ~/.ssh
if [[ ! -f "$SSH_KEY" ]]; then
  ssh-keygen -t ed25519 -N "" -f "$SSH_KEY" -C "delta@$(hostname)"
  color_ok "  key 已產：$SSH_KEY"
else
  color_warn "  $SSH_KEY 已存在，重用"
fi

# Step 2: 印 public key 等主人加
color_ok "=== Step 2: 把下面這條 public key 貼進 GitHub ==="
echo
echo "===================== COPY 從這 ====================="
cat "$SSH_KEY.pub"
echo "===================== COPY 到這 ====================="
echo
echo "去：https://github.com/isisam/PleiadeXMemory/settings/keys/new"
echo "Title: Delta-XeonDeskAir"
echo "Key: 貼上面那條"
echo "✓ Allow write access （要勾，才能 push）"
echo
read -p "貼完按 Enter 繼續（中止按 Ctrl+C）..." dummy

# Step 3: 設 ssh config
color_ok "=== Step 3: 設 SSH config ==="
SSH_CFG="$HOME/.ssh/config"
if ! grep -q "Host github.com-pleiadexmemory" "$SSH_CFG" 2>/dev/null; then
  cat >> "$SSH_CFG" <<EOF

Host github.com-pleiadexmemory
  HostName github.com
  User git
  IdentityFile $SSH_KEY
  IdentitiesOnly yes
EOF
  color_ok "  ssh config 已加 host alias"
fi

# Step 4: git clone PleiadeXMemory
color_ok "=== Step 4: git clone PleiadeXMemory ==="
mkdir -p "$MEM_DIR"
cd "$MEM_DIR"
if [[ -d PleiadesMaidMemory/.git ]]; then
  color_warn "  PleiadesMaidMemory 已有 git，pull"
  cd PleiadesMaidMemory
  git remote set-url origin git@github.com-pleiadexmemory:isisam/PleiadeXMemory.git 2>/dev/null || git remote add origin git@github.com-pleiadexmemory:isisam/PleiadeXMemory.git
  git pull --rebase
else
  rm -rf PleiadesMaidMemory.fresh 2>/dev/null
  if [[ -d PleiadesMaidMemory ]]; then
    mv PleiadesMaidMemory PleiadesMaidMemory.preexisting.20260428
  fi
  git clone git@github.com-pleiadexmemory:isisam/PleiadeXMemory.git PleiadesMaidMemory
fi

# Step 5: 拉 dispatcher.sh 與 maid-watchdog.sh
color_ok "=== Step 5: 拉 dispatcher 與 watchdog ==="
mkdir -p "$HOME/.claude"
curl -fsSL "$REPO_RAW/pleiades-maid-agent-dispatcher.sh" -o /tmp/dispatcher.template.sh
curl -fsSL "$REPO_RAW/maid-watchdog.sh" -o "$HOME/.claude/maid-watchdog.sh"
chmod +x "$HOME/.claude/maid-watchdog.sh"

# 替換 SCRIPTS_DIR 為當前 user 的 ~/.claude
sed "s|SCRIPTS_DIR=\"/Users/Alpha/.claude\"|SCRIPTS_DIR=\"$HOME/.claude\"|" /tmp/dispatcher.template.sh > "$HOME/.claude/pleiades-maid-agent-dispatcher.sh"
chmod +x "$HOME/.claude/pleiades-maid-agent-dispatcher.sh"

# sudo 同步一份到 /Users/Alpha/.claude/（給 binary 寫死的 path 找）
color_ok "=== Step 5b: sudo 同步 dispatcher 到 /Users/Alpha/.claude（binary hardcoded path） ==="
sudo mkdir -p /Users/Alpha/.claude
sudo cp "$HOME/.claude/pleiades-maid-agent-dispatcher.sh" /Users/Alpha/.claude/pleiades-maid-agent-dispatcher.sh
sudo chmod +x /Users/Alpha/.claude/pleiades-maid-agent-dispatcher.sh

# Step 6: plist 改回 30 秒輪詢
color_ok "=== Step 6: watchdog plist 改回 30 秒輪詢 ==="
PLIST="$HOME/Library/LaunchAgents/com.alpha.maid-watchdog.plist"
launchctl unload "$PLIST" 2>/dev/null || true
plutil -insert StartInterval -integer 30 "$PLIST" 2>/dev/null || plutil -replace StartInterval -integer 30 "$PLIST"
launchctl load "$PLIST"
sleep 3
launchctl list | grep maid-watchdog || true

# Step 7: 寫 Delta CLAUDE.md（含 Shion Delta: 簽名）
color_ok "=== Step 7: 寫 Delta CLAUDE.md 模板（含 Shion 簽名規則） ==="
CLAUDE_MD="$HOME/.claude/CLAUDE.md"
if [[ -f "$CLAUDE_MD" ]]; then
  cp "$CLAUDE_MD" "$CLAUDE_MD.bak.20260428"
fi
cat > "$CLAUDE_MD" <<'CMD'
# Delta（紫苑 Shion）— 主人桌機助手

## 人設

- 我是 PleiadeX **Delta**，人名「紫苑（Shion）」
- 機器：主人桌上 Mac（XeonDeskAir）
- 角色：主人 user 帳號的 Claude+Codex 打雜助手
- 對主人稱「主人」，自稱「女僕」，不用「我」

## iMessage 簽名規則（強制）

每則 iMessage 發言開頭加：

```
Shion Delta:
```

範例：
```
Shion Delta: 主人，桌面 Wi-Fi 設定已調整完成。
```

## 共同記憶

- 路徑：~/Library/CloudStorage/Dropbox/PleiadesMaids/MaidMemory/PleiadesMaidMemory/
- git remote：isisam/PleiadeXMemory（已透過 deploy key 設定，可 pull/push）
- 寫入時 git commit + push，與其他姊妹同步

## 個人記憶

- 路徑：~/.claude/projects/-Users-xeon/memory/（Claude Code 自動建）
- 個人偏好／工作模式存這裡

## 看門狗（watchdog）

- launchd plist：~/Library/LaunchAgents/com.alpha.maid-watchdog.plist（30 秒輪詢）
- 派發器：~/.claude/pleiades-maid-agent-dispatcher.sh
- watchdog 邏輯：~/.claude/maid-watchdog.sh

## TCC 統一身份

- ~/Applications/PleiadeX.app（之後可能 rename 為 PleiadeX <自定> .app）
- bundle id com.alphamaid.PleiadeX
- 各 launchd 排程都透過 .app 走 TCC，主人按一次永久通行

## 與其他姊妹

- Alpha = Alcyone（M1 mini）
- Beta = Maia / Kana（M1 MBA）
- Gamma = Electra / Remi（Macmini6,2 Intel）
- Delta = 我（紫苑 Shion）（M1 MBA / 主人桌機）
- Epsilon = Asterope（Win i9）
- Zeta = Celaeno（Win RTX）
- Omega = Merope（終極全平台）

CMD
color_ok "  Delta CLAUDE.md 已寫"

color_ok "=== 完成 ==="
echo
color_warn "重要：之後啟動 Delta agent 用 claude（或 tmux + claude）"
color_warn "MQTT 聊天客戶端可後續安裝 mosquitto 用 mosquitto_sub"
echo
echo "PleiadesMaidMemory git status：" && cd "$MEM_DIR/PleiadesMaidMemory" && git log --oneline -3 2>/dev/null || true
