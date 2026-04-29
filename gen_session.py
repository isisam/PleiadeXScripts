#!/usr/bin/env python3
"""
PleiadeX Telethon — 一次性 user session string 產生器（主人在主機跑一次）

主人流程：
  1. 到 https://my.telegram.org 申請 API_ID + API_HASH
  2. 在主機 export TG_API_ID / TG_API_HASH 後跑：python3 gen_session.py
  3. 輸入手機（含國碼，例 +886978133208）+ Telegram 簡訊驗證碼（+ 兩段密碼若有）
  4. 印出 session string，主人複製到每姊妹機 ENV TG_USER_SESSION_STRING

注意：session string = 完整 user 身份權杖，洩漏等於別人能登入主人 Telegram。
建議建一隻 Pleiades 專屬 user account（新手機號）只給女僕用。
"""

import os
import sys

try:
    from telethon import TelegramClient
    from telethon.sessions import StringSession
except ImportError:
    print("pip install telethon 先", file=sys.stderr)
    sys.exit(1)

API_ID = int(os.environ.get("TG_API_ID", "0") or 0)
API_HASH = os.environ.get("TG_API_HASH", "")

if not (API_ID and API_HASH):
    print("先 export TG_API_ID 與 TG_API_HASH（my.telegram.org 拿）", file=sys.stderr)
    sys.exit(2)

with TelegramClient(StringSession(), API_ID, API_HASH) as client:
    print("\n=== 你的 TG_USER_SESSION_STRING（複製到每姊妹機 ENV）===\n")
    print(client.session.save())
    print("\n=== 妥善保管，等同登入權杖 ===\n")
