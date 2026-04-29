#!/usr/bin/env python3
"""
PleiadeX Telethon scanner — 用主人 Telegram user account 當 event bus

主人在每台姊妹機都登入自己的 Telegram user account（多裝置登入），姊妹用
此 scanner 去掃主人帳號的訊息流。看到工作群或被 @ 自己角色的訊息 → 注入
姊妹主線 tmux；姊妹回覆時呼叫自家 bot token 從 bot 視角發回同 chat，達成
跨機 multi-agent broadcast，不靠 MQTT broker。

訊息來源：主人 user account 看到的所有 chat（含 bot、群組、其他姊妹 bot）。
過濾：只處理白名單 chat_id（預設 PleiadeX 工作群 -5277171676）。
觸發：text 含 @<AGENT> 或 @all 或 @PLEIADEX_AGENT_ALIAS。
回覆路徑：姊妹自家 bot token via Bot API sendMessage 到同 chat_id。
dedupe：Telegram message_id（保最近 500 筆於 ~/.pleiadex/telethon/seen.txt）。

ENV：
  TG_API_ID, TG_API_HASH         主人在 my.telegram.org 申請（一次性）
  TG_USER_SESSION_STRING         主人用 gen_session.py 產的 user session（對等多裝置登入）
  PLEIADEX_AGENT                 姊妹角色 (Alpha / Beta / Gamma...)
  AGENT_BOT_TOKEN                姊妹自家 Telegram bot token（如 KanaBeta_bot）
  PLEIADEX_CHAT_ALLOW            CSV 白名單 chat_id（預設 -5277171676）
  TELETHON_TMUX_SESSION          注入目的 tmux session（預設 claude-imessage）

依賴：pip install telethon
"""

import asyncio
import json
import os
import subprocess
import sys
import urllib.parse
import urllib.request
from collections import deque
from pathlib import Path

try:
    from telethon import TelegramClient, events
    from telethon.sessions import StringSession
except ImportError:
    print("ERROR: telethon 未裝（pip install telethon）", file=sys.stderr)
    sys.exit(1)

AGENT = os.environ.get("PLEIADEX_AGENT", "Alpha")
API_ID = int(os.environ.get("TG_API_ID", "0") or 0)
API_HASH = os.environ.get("TG_API_HASH", "")
SESSION_STR = os.environ.get("TG_USER_SESSION_STRING", "")
BOT_TOKEN = os.environ.get("AGENT_BOT_TOKEN", "")
TMUX_SESSION = os.environ.get("TELETHON_TMUX_SESSION", "claude-imessage")
ALLOW_RAW = os.environ.get("PLEIADEX_CHAT_ALLOW", "-5277171676")
ALLOW_CHATS = {int(x.strip()) for x in ALLOW_RAW.split(",") if x.strip()}

SEEN_FILE = Path.home() / ".pleiadex" / "telethon" / "seen.txt"
SEEN_FILE.parent.mkdir(parents=True, exist_ok=True)
SEEN_LIMIT = 500


def load_seen():
    if not SEEN_FILE.exists():
        return deque(maxlen=SEEN_LIMIT)
    try:
        lines = SEEN_FILE.read_text(encoding="utf-8").splitlines()
        return deque(lines[-SEEN_LIMIT:], maxlen=SEEN_LIMIT)
    except Exception:
        return deque(maxlen=SEEN_LIMIT)


def save_seen(seen):
    try:
        SEEN_FILE.write_text("\n".join(seen) + "\n", encoding="utf-8")
    except Exception as e:
        print(f"[telethon] save_seen err: {e}", file=sys.stderr)


def _find_tmux():
    for p in ("/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/usr/bin/tmux"):
        if os.path.exists(p):
            return p
    return "tmux"


TMUX_BIN = _find_tmux()


def tmux_inject(prompt):
    try:
        subprocess.run(
            [TMUX_BIN, "send-keys", "-t", TMUX_SESSION, prompt, "Enter"],
            check=False, timeout=5,
        )
        print(f"[telethon] injected → {TMUX_SESSION}: {prompt[:80]}")
    except Exception as e:
        print(f"[telethon] tmux inject err: {e}", file=sys.stderr)


def is_mentioned(text):
    if not text:
        return False
    low = text.lower()
    tags = (f"@{AGENT}".lower(), "@all", "@全部", "@everyone")
    return any(t in low for t in tags)


def bot_send(chat_id, text):
    """姊妹自家 bot 從 bot 視角回到同 chat。"""
    if not BOT_TOKEN:
        print("[telethon] AGENT_BOT_TOKEN 未設，跳過 bot reply", file=sys.stderr)
        return
    url = f"https://api.telegram.org/bot{BOT_TOKEN}/sendMessage"
    data = urllib.parse.urlencode({"chat_id": chat_id, "text": text}).encode()
    try:
        with urllib.request.urlopen(url, data=data, timeout=10) as r:
            r.read()
    except Exception as e:
        print(f"[telethon] bot_send err: {e}", file=sys.stderr)


seen = load_seen()


async def main():
    if not (API_ID and API_HASH and SESSION_STR):
        print("ERROR: TG_API_ID / TG_API_HASH / TG_USER_SESSION_STRING 必設", file=sys.stderr)
        sys.exit(2)

    client = TelegramClient(StringSession(SESSION_STR), API_ID, API_HASH)
    await client.start()
    me = await client.get_me()
    print(f"[telethon] logged in as user_id={me.id} agent={AGENT} allow={ALLOW_CHATS}")

    @client.on(events.NewMessage())
    async def handler(event):
        chat_id = event.chat_id
        if ALLOW_CHATS and chat_id not in ALLOW_CHATS:
            return
        msg_id = f"{chat_id}:{event.message.id}"
        if msg_id in seen:
            return
        sender = await event.get_sender()
        sender_name = getattr(sender, "username", None) or getattr(sender, "first_name", "?")
        if getattr(sender, "id", None) == me.id:
            return  # 主人自己發的不回，避免 echo
        text = event.message.message or ""
        seen.append(msg_id)
        save_seen(seen)
        if not is_mentioned(text):
            return
        kind = f"@{AGENT}"
        prompt = (
            f"[Telethon 注入 {kind}] {sender_name} 在 Telegram chat={chat_id} 發訊息："
            f'"{text}"。請依女僕守則跟答（呼叫 telegram bot reply 工具或直接 '
            f"AGENT_BOT_TOKEN sendMessage 到 chat_id={chat_id}）。msg_id={msg_id}"
        )
        tmux_inject(prompt)

    print(f"[telethon] listening… tmux→{TMUX_SESSION}")
    await client.run_until_disconnected()


if __name__ == "__main__":
    asyncio.run(main())
