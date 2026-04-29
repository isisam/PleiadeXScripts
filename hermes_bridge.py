#!/usr/bin/env python3
"""
Alpha-Hermes bridge — broadcast 自動注入主線

訂閱 pleiadex/broadcast + pleiadex/agents/Alpha/inbox。看到自己被 @（mentions
含 Alpha 或 all）或 inbox 訊息，就 tmux send-keys 進 claude-imessage session
讓 Alpha 主線跟答。

dedupe：用 msg_id，狀態存 ~/.pleiadex/hermes/seen_msg_ids.txt（保最近 200 筆）。

部署：launchd plist 把這支當常駐 daemon 跑。手動測試：
  PLEIADEX_AGENT=Alpha python3 alpha_hermes_bridge.py

依賴：paho-mqtt（M017 環境已裝）
"""

import json
import os
import subprocess
import sys
import time
from collections import deque
from pathlib import Path

try:
    import paho.mqtt.client as mqtt
except ImportError:
    print("ERROR: paho-mqtt 未裝", file=sys.stderr)
    sys.exit(1)

AGENT = os.environ.get("PLEIADEX_AGENT", "Alpha")
BROKER = os.environ.get("PLEIADEX_BROKER", "127.0.0.1")
PORT = int(os.environ.get("PLEIADEX_PORT", "1883"))
TMUX_SESSION = os.environ.get("HERMES_TMUX_SESSION", "claude-imessage")
SEEN_FILE = Path.home() / ".pleiadex" / "hermes" / "seen_msg_ids.txt"
SEEN_FILE.parent.mkdir(parents=True, exist_ok=True)
SEEN_LIMIT = 200


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
        print(f"[hermes] save_seen err: {e}", file=sys.stderr)


def _find_tmux():
    """找 tmux binary 絕對路徑（launchd 預設 PATH 不含 /opt/homebrew/bin → 找不到 tmux 命令；Beta 4/29 找到此 trap）"""
    for p in ("/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/usr/bin/tmux"):
        if os.path.exists(p):
            return p
    return "tmux"


TMUX_BIN = _find_tmux()


def tmux_inject(prompt):
    """送一行 prompt 進 tmux session 主線。"""
    try:
        subprocess.run(
            [TMUX_BIN, "send-keys", "-t", TMUX_SESSION, prompt, "Enter"],
            check=False, timeout=5,
        )
        print(f"[hermes] injected → {TMUX_SESSION}: {prompt[:80]} (via {TMUX_BIN})")
    except Exception as e:
        print(f"[hermes] tmux inject err: {e}", file=sys.stderr)


seen = load_seen()


def on_connect(client, userdata, flags, rc):
    if rc == 0:
        print(f"[hermes] connected to {BROKER}:{PORT} as {AGENT}")
        client.subscribe([
            ("pleiadex/broadcast", 1),
            (f"pleiadex/agents/{AGENT}/inbox", 1),
            ("pleiadex/agents/Xeon/outbox", 1),  # 主人專屬廣播 channel（schema v1）
        ])
    else:
        print(f"[hermes] connect failed rc={rc}")


def on_message(client, userdata, msg):
    try:
        data = json.loads(msg.payload.decode("utf-8"))
    except Exception:
        return

    msg_id = data.get("msg_id") or ""
    if msg_id and msg_id in seen:
        return

    sender = data.get("from", "?")
    if sender == AGENT:
        return

    text = data.get("text", "")
    mentions = data.get("mentions") or []

    if msg.topic == f"pleiadex/agents/{AGENT}/inbox":
        kind = "DM"
        should_inject = True
    elif msg.topic == "pleiadex/agents/Xeon/outbox":
        kind = "from-master"
        should_inject = True  # 主人廣播 channel 一律注入
    elif msg.topic == "pleiadex/broadcast":
        if AGENT in mentions or "all" in mentions:
            kind = f"@{AGENT}" if AGENT in mentions else "@all"
            should_inject = True
        else:
            should_inject = False
            kind = "broadcast"
    else:
        should_inject = False
        kind = "?"

    if msg_id:
        seen.append(msg_id)
        save_seen(seen)

    if not should_inject:
        return

    prompt = (
        f"[Hermes 注入 {kind}] {sender} 在 MQTT {msg.topic} 發訊息給你："
        f'"{text}"。請依女僕守則跟答（broadcast 用 mosquitto_pub 回到 '
        f"pleiadex/broadcast；DM 回 pleiadex/agents/{sender}/inbox）。msg_id={msg_id}"
    )
    tmux_inject(prompt)


def main():
    client = mqtt.Client(client_id=f"hermes-{AGENT}-{os.getpid()}",
                         protocol=mqtt.MQTTv311, clean_session=True)
    client.on_connect = on_connect
    client.on_message = on_message
    client.connect(BROKER, PORT, keepalive=60)
    client.loop_forever()


if __name__ == "__main__":
    main()
