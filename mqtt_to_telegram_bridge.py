#!/usr/bin/env python3
"""
mqtt_to_telegram_bridge — broker ↔ 主人 Telegram 雙向橋接

跑在 Alpha 機器（broker host）。任務：
  (A) MQTT → Telegram：訂 pleiadex/broadcast + pleiadex/agents/Xeon/inbox，
      過濾 mention 含 master/Xeon → format → 推主人 DM
  (B) Telegram → MQTT：long-poll getUpdates，主人 DM 訊息 publish 到
      pleiadex/agents/Xeon/outbox 給所有姊妹 hermes 注入

dedupe：msg_id（MQTT 端）+ update_id（Telegram 端）。狀態存
~/.pleiadex/mqtt_telegram/ 下 JSON。

環境變數：
  TELEGRAM_BOT_TOKEN   必填，Bot API token（launchd plist 裡傳）
  TELEGRAM_MASTER_ID   主人 user_id，預設 1070686431
  PLEIADEX_BROKER      broker host，預設 127.0.0.1
  PLEIADEX_PORT        broker port，預設 1883
  TELEGRAM_POLL_TIMEOUT  long poll timeout 秒，預設 25

依賴：paho-mqtt（已裝）；Telegram 用 stdlib urllib 直 call。
"""

import json
import os
import sys
import threading
import time
import uuid
from collections import deque
from datetime import datetime, timezone
from pathlib import Path
from urllib import error as urlerror, parse as urlparse, request as urlrequest

try:
    import paho.mqtt.client as mqtt
except ImportError:
    print("ERROR: paho-mqtt 未裝（pip install paho-mqtt==1.6.1）", file=sys.stderr)
    sys.exit(1)

# ---------- config ----------
BOT_TOKEN = os.environ.get("TELEGRAM_BOT_TOKEN", "").strip()
MASTER_ID = int(os.environ.get("TELEGRAM_MASTER_ID", "1070686431"))
BROKER = os.environ.get("PLEIADEX_BROKER", "127.0.0.1")
PORT = int(os.environ.get("PLEIADEX_PORT", "1883"))
POLL_TIMEOUT = int(os.environ.get("TELEGRAM_POLL_TIMEOUT", "25"))
STATE_DIR = Path.home() / ".pleiadex" / "mqtt_telegram"
STATE_DIR.mkdir(parents=True, exist_ok=True)
SEEN_MSG_FILE = STATE_DIR / "seen_msg_ids.txt"
LAST_UPDATE_FILE = STATE_DIR / "last_update_id.txt"
SEEN_LIMIT = 500
TG_API = f"https://api.telegram.org/bot{BOT_TOKEN}"

if not BOT_TOKEN:
    print("ERROR: TELEGRAM_BOT_TOKEN 未設定", file=sys.stderr)
    sys.exit(2)

# ---------- state ----------
def _load_deque(path):
    if not path.exists():
        return deque(maxlen=SEEN_LIMIT)
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
        return deque(lines[-SEEN_LIMIT:], maxlen=SEEN_LIMIT)
    except Exception:
        return deque(maxlen=SEEN_LIMIT)

def _save_deque(path, dq):
    try:
        path.write_text("\n".join(dq) + "\n", encoding="utf-8")
    except Exception as e:
        print(f"[bridge] save state err: {e}", file=sys.stderr)

seen_msg_ids = _load_deque(SEEN_MSG_FILE)

def _load_last_update():
    if not LAST_UPDATE_FILE.exists():
        return 0
    try:
        return int(LAST_UPDATE_FILE.read_text().strip() or "0")
    except Exception:
        return 0

def _save_last_update(n):
    try:
        LAST_UPDATE_FILE.write_text(str(n), encoding="utf-8")
    except Exception as e:
        print(f"[bridge] save last_update err: {e}", file=sys.stderr)

# ---------- Telegram HTTP ----------
def tg_call(method, params=None, timeout=30):
    url = f"{TG_API}/{method}"
    data = urlparse.urlencode(params or {}).encode("utf-8")
    req = urlrequest.Request(url, data=data, method="POST")
    try:
        with urlrequest.urlopen(req, timeout=timeout) as resp:
            return json.loads(resp.read().decode("utf-8"))
    except urlerror.HTTPError as e:
        body = e.read().decode("utf-8", errors="replace")
        print(f"[bridge] TG {method} HTTP {e.code}: {body}", file=sys.stderr)
        return None
    except Exception as e:
        print(f"[bridge] TG {method} err: {e}", file=sys.stderr)
        return None

def tg_send(text):
    """送純文字訊息給主人 DM。"""
    if len(text) > 4000:
        text = text[:3990] + "…(截斷)"
    res = tg_call("sendMessage", {
        "chat_id": MASTER_ID,
        "text": text,
        "disable_web_page_preview": "true",
    })
    if res and res.get("ok"):
        return True
    print(f"[bridge] tg_send 失敗: {res}", file=sys.stderr)
    return False

# ---------- MQTT → Telegram ----------
mqtt_client = None  # 全域 publish handle

def _is_for_master(topic, data):
    """判斷這條訊息是否該轉給主人。
    inbox 一律收；broadcast 看 mentions 是否含 master/Xeon。
    """
    if topic == "pleiadex/agents/Xeon/inbox":
        return True
    mentions = [str(m).lower() for m in (data.get("mentions") or [])]
    if any(m in ("master", "xeon", "主人", "all") for m in mentions):
        return True
    return False

def _format_for_master(topic, data):
    sender = data.get("from", "?")
    text = data.get("text", "")
    if topic == "pleiadex/agents/Xeon/inbox":
        prefix = f"[DM from {sender}]"
    elif topic == "pleiadex/broadcast":
        prefix = f"[broadcast {sender}]"
    else:
        prefix = f"[{topic} {sender}]"
    return f"{prefix}\n{text}"

def on_connect(client, userdata, flags, rc):
    if rc == 0:
        print(f"[bridge] mqtt connected {BROKER}:{PORT}")
        client.subscribe([
            ("pleiadex/broadcast", 1),
            ("pleiadex/agents/Xeon/inbox", 1),
        ])
    else:
        print(f"[bridge] mqtt connect failed rc={rc}")

def on_message(client, userdata, msg):
    try:
        data = json.loads(msg.payload.decode("utf-8"))
    except Exception:
        return
    msg_id = data.get("msg_id") or ""
    if msg_id and msg_id in seen_msg_ids:
        return
    if not _is_for_master(msg.topic, data):
        if msg_id:
            seen_msg_ids.append(msg_id)
            _save_deque(SEEN_MSG_FILE, seen_msg_ids)
        return
    # 不轉發主人自己發的（避免迴圈）
    if str(data.get("from", "")).lower() in ("xeon", "master", "主人"):
        if msg_id:
            seen_msg_ids.append(msg_id)
            _save_deque(SEEN_MSG_FILE, seen_msg_ids)
        return
    text = _format_for_master(msg.topic, data)
    if tg_send(text):
        print(f"[bridge] mqtt→tg: {msg.topic} {msg_id}")
    if msg_id:
        seen_msg_ids.append(msg_id)
        _save_deque(SEEN_MSG_FILE, seen_msg_ids)

def mqtt_loop():
    global mqtt_client
    client = mqtt.Client(client_id=f"mqtt2tg-{os.getpid()}",
                         protocol=mqtt.MQTTv311, clean_session=True)
    client.on_connect = on_connect
    client.on_message = on_message
    while True:
        try:
            client.connect(BROKER, PORT, keepalive=60)
            mqtt_client = client
            client.loop_forever(retry_first_connection=True)
        except Exception as e:
            print(f"[bridge] mqtt loop err: {e}，10 秒重連", file=sys.stderr)
            time.sleep(10)

# ---------- Telegram → MQTT ----------
def telegram_loop():
    last_update = _load_last_update()
    print(f"[bridge] tg poll start，offset={last_update + 1 if last_update else 0}")
    while True:
        params = {"timeout": POLL_TIMEOUT, "allowed_updates": json.dumps(["message"])}
        if last_update:
            params["offset"] = last_update + 1
        res = tg_call("getUpdates", params, timeout=POLL_TIMEOUT + 10)
        if not res or not res.get("ok"):
            time.sleep(5)
            continue
        for update in res.get("result", []):
            uid = update.get("update_id", 0)
            if uid > last_update:
                last_update = uid
                _save_last_update(last_update)
            message = update.get("message") or {}
            sender = (message.get("from") or {}).get("id")
            if sender != MASTER_ID:
                continue  # 只接受主人 DM
            text = message.get("text", "").strip()
            if not text:
                continue
            # 反向：publish 到 Xeon/outbox 給所有姊妹
            payload = {
                "from": "Xeon",
                "text": text,
                "msg_id": f"tg-{uid}-{uuid.uuid4().hex[:8]}",
                "ts": datetime.now(timezone.utc).isoformat(),
                "source": "telegram",
            }
            if mqtt_client and mqtt_client.is_connected():
                try:
                    mqtt_client.publish(
                        "pleiadex/agents/Xeon/outbox",
                        json.dumps(payload, ensure_ascii=False),
                        qos=1,
                    )
                    seen_msg_ids.append(payload["msg_id"])
                    _save_deque(SEEN_MSG_FILE, seen_msg_ids)
                    print(f"[bridge] tg→mqtt: outbox {payload['msg_id']}")
                except Exception as e:
                    print(f"[bridge] publish err: {e}", file=sys.stderr)
            else:
                print("[bridge] mqtt 未連線，丟棄主人訊息", file=sys.stderr)

# ---------- main ----------
def main():
    print(f"[bridge] start，master={MASTER_ID} broker={BROKER}:{PORT}")
    t = threading.Thread(target=telegram_loop, daemon=True)
    t.start()
    mqtt_loop()  # 主執行緒跑 mqtt loop_forever

if __name__ == "__main__":
    main()
