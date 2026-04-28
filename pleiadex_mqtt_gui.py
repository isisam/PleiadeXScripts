#!/usr/bin/env python3
"""
PleiadeX MQTT 監控 + 聊天 GUI v2

雙擊「MQTT 聊天.app」啟動 native Tkinter GUI 視窗：
  • 訂閱 # 看 broker 全部 topic（誰傳給誰一目了然）
  • 「<sender> → <to>: 訊息」格式
  • macOS Cmd+C / Cmd+V / Cmd+X / Cmd+A 鍵盤支援
  • dark Catppuccin 配色
  • 自動重連、LWT、online retained

依賴：paho-mqtt
用法：python3 pleiadex_mqtt_gui.py [--agent DeltaMonitor] [--broker 192.168.1.200]
"""

import argparse
import datetime
import json
import sys
import threading
import tkinter as tk
from tkinter import scrolledtext

try:
    import paho.mqtt.client as mqtt
except ImportError:
    print("缺 paho-mqtt：pip3 install --user paho-mqtt", file=sys.stderr)
    sys.exit(1)


def now_ts():
    return datetime.datetime.now().strftime("%Y-%m-%dT%H:%M:%S+0800")


def parse_topic(topic: str):
    """解析 broker topic 推「to」與「kind」"""
    parts = topic.split("/")
    if len(parts) >= 2 and parts[0] == "pleiadex":
        if parts[1] == "broadcast":
            return ("all", "broadcast")
        if parts[1] == "agents" and len(parts) >= 4:
            return (parts[2], parts[3])  # to=agent, kind=inbox/status/hardware/etc
        if parts[1] == "chat" and len(parts) >= 3:
            return ("chat-" + parts[2], "chat")
        if parts[1] == "system":
            return ("system", parts[2] if len(parts) > 2 else "")
    return (topic, "raw")


class ChatGUI(tk.Tk):
    def __init__(self, agent: str, broker: str, port: int):
        super().__init__()
        self.agent = agent
        self.broker = broker
        self.port = port

        self.title(f"PleiadeX MQTT 監控 — {agent} @ {broker}")
        self.geometry("960x640")
        self.configure(bg="#1e1e2e")

        # macOS 鍵盤快捷鍵（cmd+C/V/X/A）
        self.bind_all("<Command-c>", lambda e: e.widget.event_generate("<<Copy>>"))
        self.bind_all("<Command-v>", lambda e: e.widget.event_generate("<<Paste>>"))
        self.bind_all("<Command-x>", lambda e: e.widget.event_generate("<<Cut>>"))
        self.bind_all("<Command-a>", lambda e: e.widget.event_generate("<<SelectAll>>"))

        # 訊息 stream
        self.text = scrolledtext.ScrolledText(
            self, wrap="word", state="normal",
            bg="#1e1e2e", fg="#cdd6f4",
            insertbackground="#cdd6f4",
            selectbackground="#45475a",
            font=("Menlo", 11)
        )
        self.text.pack(fill="both", expand=True, padx=8, pady=(8, 4))
        self.text.tag_config("system",    foreground="#fab387")
        self.text.tag_config("me",        foreground="#a6e3a1")
        self.text.tag_config("status",    foreground="#7f849c")
        self.text.tag_config("dm",        foreground="#89dceb")
        self.text.tag_config("broadcast", foreground="#f9e2af")
        self.text.tag_config("error",     foreground="#f38ba8")
        self.text.tag_config("ts",        foreground="#6c7086")

        # 底部輸入欄
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

        self.append("[help] 已訂閱 #（看全部 topic 誰傳給誰）｜直接打字＝廣播 ｜/to <agent> 訊息＝DM｜/quit｜Cmd+C/V/A 可用", tag="system")

        # MQTT
        self.client = mqtt.Client(client_id=f"{agent}-monitor-{datetime.datetime.now().strftime('%H%M%S')}")
        self.client.on_connect = self.on_connect
        self.client.on_disconnect = self.on_disconnect
        self.client.on_message = self.on_message
        will = json.dumps({"agent": agent, "status": "offline_lwt", "ts": now_ts()})
        self.client.will_set(f"pleiadex/agents/{agent}/status", will, qos=1, retain=True)

        threading.Thread(target=self.mqtt_loop, daemon=True).start()
        self.protocol("WM_DELETE_WINDOW", self.on_close)

    # ---- MQTT ----
    def mqtt_loop(self):
        import time as _time
        while True:
            try:
                self.client.connect(self.broker, self.port, 60)
                self.client.loop_forever(retry_first_connection=True)
            except Exception as e:
                self.append(f"[error] connect failed: {e}（5s 重試）", tag="error")
                _time.sleep(5)

    def on_connect(self, client, userdata, flags, rc):
        if rc == 0:
            self.append(f"[system] connected to {self.broker}:{self.port}, 訂閱 #", tag="system")
            client.subscribe("#", qos=0)
            online = json.dumps({"agent": self.agent, "status": "online_gui", "ts": now_ts()})
            client.publish(f"pleiadex/agents/{self.agent}/status", online, qos=1, retain=True)
        else:
            self.append(f"[error] connect rc={rc}", tag="error")

    def on_disconnect(self, client, userdata, rc):
        self.append(f"[system] disconnected rc={rc}（自動重連中）", tag="system")

    def on_message(self, client, userdata, msg):
        try:
            payload_str = msg.payload.decode(errors="replace")
            try:
                payload = json.loads(payload_str)
            except Exception:
                payload = {"text": payload_str}

            sender = payload.get("from", payload.get("agent", "?"))
            text = payload.get("text", payload.get("status", payload.get("event", "")))
            if not text:
                text = json.dumps({k: v for k, v in payload.items() if k not in ("from", "to", "agent", "ts")}, ensure_ascii=False)
            ts_raw = payload.get("ts", "")
            short_ts = ts_raw.split("T")[-1][:8] if "T" in ts_raw else datetime.datetime.now().strftime("%H:%M:%S")

            to, kind = parse_topic(msg.topic)

            if kind == "status" or kind == "hardware":
                line = f"[{short_ts}] {to} ({kind}): {text}"
                tag = "status"
            elif kind == "broadcast" or to == "all":
                line = f"[{short_ts}] {sender} → 全體廣播: {text}"
                tag = "broadcast"
            elif kind == "inbox":
                line = f"[{short_ts}] {sender} → {to} (DM): {text}"
                tag = "dm"
            else:
                line = f"[{short_ts}] [{msg.topic}] <{sender}> {text[:200]}"
                tag = None

            self.append(line, tag=tag)
        except Exception as e:
            self.append(f"[error] parse {msg.topic}: {e}", tag="error")

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
                self.append(f"[me → {target} (DM)] {body}", tag="me")
            else:
                self.append("[help] /to <agent> <text>", tag="system")
        elif text.startswith("/sub "):
            topic = text.split(" ", 1)[1].strip()
            self.client.subscribe(topic)
            self.append(f"[system] subscribed: {topic}", tag="system")
        elif text == "/help":
            self.append("[help] /to <agent> 訊息 / /sub <topic> / /quit / 其他直接 broadcast", tag="system")
        elif text == "/quit":
            self.on_close()
        else:
            payload = json.dumps({"from": self.agent, "to": "broadcast", "text": text, "ts": now_ts()})
            self.client.publish("pleiadex/broadcast", payload, qos=1)
            self.append(f"[me → 全體廣播] {text}", tag="me")

    def append(self, line: str, tag: str | None = None):
        self.text.configure(state="normal")
        if tag:
            self.text.insert("end", line + "\n", tag)
        else:
            self.text.insert("end", line + "\n")
        self.text.see("end")
        # 保留 normal 狀態讓 Cmd+C select 文字（但禁止打字）
        # self.text.configure(state="disabled") removed for copy support

    def on_close(self):
        try:
            offline = json.dumps({"agent": self.agent, "status": "offline", "ts": now_ts()})
            self.client.publish(f"pleiadex/agents/{self.agent}/status", offline, qos=1, retain=True)
            self.client.disconnect()
        except Exception:
            pass
        self.destroy()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--agent", default="DeltaMonitor")
    parser.add_argument("--broker", default="192.168.1.200")
    parser.add_argument("--port", type=int, default=1883)
    args = parser.parse_args()
    ChatGUI(args.agent, args.broker, args.port).mainloop()


if __name__ == "__main__":
    main()
