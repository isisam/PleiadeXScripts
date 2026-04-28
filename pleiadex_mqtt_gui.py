#!/usr/bin/env python3
"""
PleiadeX MQTT GUI Chat Client (Tkinter)

雙擊桌面捷徑即啟動 native GUI 視窗（不是 Terminal）。
訂閱 broker 訊息，發訊到 broadcast 或指定 agent inbox。

依賴：paho-mqtt（pip install paho-mqtt）
用法：python3 pleiadex_mqtt_gui.py [--agent Delta] [--broker 192.168.1.200]
"""

import argparse
import datetime
import json
import threading
import tkinter as tk
from tkinter import scrolledtext, ttk

try:
    import paho.mqtt.client as mqtt
except ImportError as e:
    import sys
    print(f"缺 paho-mqtt：pip install --user paho-mqtt", file=sys.stderr)
    sys.exit(1)


def now_ts():
    return datetime.datetime.now().strftime("%Y-%m-%dT%H:%M:%S%z") or datetime.datetime.now().strftime("%Y-%m-%dT%H:%M:%S+0800")


class ChatGUI(tk.Tk):
    def __init__(self, agent: str, broker: str, port: int):
        super().__init__()
        self.agent = agent
        self.broker = broker
        self.port = port

        self.title(f"PleiadeX MQTT — {agent} @ {broker}")
        self.geometry("760x520")
        self.configure(bg="#1e1e2e")

        # 訊息 stream
        self.text = scrolledtext.ScrolledText(
            self, wrap="word", state="disabled",
            bg="#1e1e2e", fg="#cdd6f4",
            insertbackground="#cdd6f4",
            font=("Menlo", 12)
        )
        self.text.pack(fill="both", expand=True, padx=8, pady=(8, 4))
        self.text.tag_config("system", foreground="#fab387")
        self.text.tag_config("me", foreground="#a6e3a1")
        self.text.tag_config("error", foreground="#f38ba8")
        self.text.tag_config("ts", foreground="#7f849c")

        # 底部：輸入 + send
        bottom = tk.Frame(self, bg="#1e1e2e")
        bottom.pack(fill="x", padx=8, pady=(4, 8))
        self.entry = tk.Entry(
            bottom, bg="#313244", fg="#cdd6f4",
            insertbackground="#cdd6f4", font=("Menlo", 13),
            relief="flat"
        )
        self.entry.pack(side="left", fill="x", expand=True, ipady=6)
        self.entry.bind("<Return>", self.send)
        self.entry.focus()

        send_btn = tk.Button(
            bottom, text="送出", command=self.send,
            bg="#89b4fa", fg="#1e1e2e", relief="flat",
            font=("Menlo", 12), padx=14
        )
        send_btn.pack(side="right", padx=(6, 0))

        # 提示
        self.append("[help] 直接打字 Enter = 廣播 / /to <agent> 訊息 = 直送該 agent inbox / /sub <topic> / /quit", tag="system")

        # MQTT
        self.client = mqtt.Client(client_id=f"{agent}-gui-{datetime.datetime.now().strftime('%H%M%S')}")
        self.client.on_connect = self.on_connect
        self.client.on_disconnect = self.on_disconnect
        self.client.on_message = self.on_message
        will_payload = json.dumps({"agent": agent, "status": "offline_lwt", "ts": now_ts()})
        self.client.will_set(f"pleiadex/agents/{agent}/status", will_payload, qos=1, retain=True)

        threading.Thread(target=self.mqtt_loop, daemon=True).start()

        self.protocol("WM_DELETE_WINDOW", self.on_close)

    # ---- MQTT ----
    def mqtt_loop(self):
        while True:
            try:
                self.client.connect(self.broker, self.port, 60)
                self.client.loop_forever(retry_first_connection=True)
            except Exception as e:
                self.append(f"[error] connect failed: {e}（5 秒後重試）", tag="error")
                import time
                time.sleep(5)

    def on_connect(self, client, userdata, flags, rc):
        if rc == 0:
            self.append(f"[system] connected to {self.broker}:{self.port}", tag="system")
            client.subscribe("pleiadex/broadcast", qos=0)
            client.subscribe(f"pleiadex/agents/{self.agent}/inbox", qos=0)
            client.subscribe("pleiadex/chat/#", qos=0)
            client.subscribe("pleiadex/agents/+/status", qos=0)
            online_payload = json.dumps({"agent": self.agent, "status": "online_gui", "ts": now_ts()})
            client.publish(f"pleiadex/agents/{self.agent}/status", online_payload, qos=1, retain=True)
        else:
            self.append(f"[error] connect rc={rc}", tag="error")

    def on_disconnect(self, client, userdata, rc):
        self.append(f"[system] disconnected rc={rc}（自動重連中）", tag="system")

    def on_message(self, client, userdata, msg):
        try:
            payload = json.loads(msg.payload.decode())
            sender = payload.get("from", payload.get("agent", "?"))
            text = payload.get("text", payload.get("status", json.dumps(payload, ensure_ascii=False)))
            ts = payload.get("ts", "")
            short_ts = ts.split("T")[-1][:8] if "T" in ts else datetime.datetime.now().strftime("%H:%M:%S")
            self.append(f"[{short_ts}] [{msg.topic}] <{sender}> {text}")
        except Exception:
            self.append(f"[{msg.topic}] {msg.payload.decode(errors='replace')}")

    # ---- send ----
    def send(self, event=None):
        text = self.entry.get().strip()
        if not text:
            return
        self.entry.delete(0, "end")

        if text.startswith("/to "):
            parts = text.split(" ", 2)
            if len(parts) >= 3:
                target, body = parts[1], parts[2]
                topic = f"pleiadex/agents/{target}/inbox"
                payload = json.dumps({"from": self.agent, "to": target, "text": body, "ts": now_ts()})
                self.client.publish(topic, payload, qos=1)
                self.append(f"[me → {target}] {body}", tag="me")
            else:
                self.append("[help] /to <agent> <text>", tag="system")
        elif text.startswith("/sub "):
            topic = text.split(" ", 1)[1].strip()
            self.client.subscribe(topic)
            self.append(f"[system] subscribed: {topic}", tag="system")
        elif text == "/help":
            self.append("[help] /to <agent> 訊息 / /sub <topic> / /quit / 其他直接廣播", tag="system")
        elif text == "/quit":
            self.on_close()
        else:
            payload = json.dumps({"from": self.agent, "to": "broadcast", "text": text, "ts": now_ts()})
            self.client.publish("pleiadex/broadcast", payload, qos=1)
            self.append(f"[me → all] {text}", tag="me")

    def append(self, line: str, tag: str | None = None):
        self.text.configure(state="normal")
        if tag:
            self.text.insert("end", line + "\n", tag)
        else:
            self.text.insert("end", line + "\n")
        self.text.see("end")
        self.text.configure(state="disabled")

    def on_close(self):
        try:
            offline_payload = json.dumps({"agent": self.agent, "status": "offline", "ts": now_ts()})
            self.client.publish(f"pleiadex/agents/{self.agent}/status", offline_payload, qos=1, retain=True)
            self.client.disconnect()
        except Exception:
            pass
        self.destroy()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--agent", default="Delta")
    parser.add_argument("--broker", default="192.168.1.200")
    parser.add_argument("--port", type=int, default=1883)
    args = parser.parse_args()
    ChatGUI(args.agent, args.broker, args.port).mainloop()


if __name__ == "__main__":
    main()
