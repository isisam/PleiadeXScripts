#!/usr/bin/env python3
"""
Delta Dashboard — 主人桌上 Mac 用的 PleiadeX MQTT 中控 GUI（v1, 2026-04-28）

四分頁設計（主人 04:04 規格）：
  Tab 1 聊天頁  — 狀態燈列 + 辦公室大廳 + 快速跟 Alpha 交談 + 下發文輸入
  Tab 2 系統   — 每位女僕 主機描述/PID/inbox/outbox/活躍度 + broker 狀態
  Tab 3 日課表 — 從 Timeline.md 讀排程一覽（v1 唯讀）
  Tab 4 指令   — 快速按鈕 /cc clear、/cc help、/cc status、/cc compact 等

執行：
  python3 delta_dashboard.py

相依：
  paho-mqtt（pip3 install --user --break-system-packages paho-mqtt）
  tkinter（Python 內建）

訊息 / 狀態協定：與其他 PleiadeX MQTT client 完全一致
  · publish 自己訊息加 from="Delta"，文本不寫 "Delta:" 前綴（client 自帶）
  · 訂閱 pleiadex/agents/Delta/inbox + pleiadex/broadcast + pleiadex/agents/+/status
"""

import json
import os
import queue
import re
import subprocess
import sys
import threading
import time
import tkinter as tk
import uuid
from datetime import datetime, timedelta
from pathlib import Path
from tkinter import ttk, scrolledtext, messagebox

try:
    import paho.mqtt.client as mqtt
except ImportError:
    print("ERROR: paho-mqtt 未安裝。pip3 install --user --break-system-packages paho-mqtt", file=sys.stderr)
    sys.exit(1)


# ─── 設定 ─────────────────────────────────────────────────────
# AGENT 預設 Delta（桌上 Mac）；Zeta 端啟動器設環境變數 PLEIADEX_AGENT=Zeta 即可共用此 dashboard。
AGENT = os.environ.get("PLEIADEX_AGENT", "Delta")
BROKER = os.environ.get("PLEIADEX_BROKER", "192.168.1.200")
PORT = int(os.environ.get("PLEIADEX_PORT", "1883"))
DASHBOARD_WIDTH = 1280
DASHBOARD_HEIGHT = 820
NOTEBOOK_WIDTH = 1264
NOTEBOOK_HEIGHT = 690

# ─── PleiadeX 暗色主題色票（v2 統一風格，學 Walsin IG System） ──
PALETTE = {
    "bg":          "#1a1d23",  # 視窗主背景
    "panel":       "#232830",  # 面板背景
    "panel_alt":   "#2c333d",  # 次面板（按鈕底）
    "panel_hover": "#3a4250",  # hover 時加深
    "border":      "#3c4452",  # 框線
    "fg":          "#ecf0f1",  # 主要文字
    "fg_dim":      "#7f8c8d",  # 次要文字 / 提示
    "fg_muted":    "#5d6770",  # 更弱
    "accent":      "#00d4ff",  # 青藍色強調（連線狀態 / 主強調）
    "success":     "#2ecc71",  # 綠
    "warning":     "#f39c12",  # 橙
    "danger":      "#e74c3c",  # 紅
    "info":        "#3498db",  # 藍
    "purple":      "#9b59b6",  # 紫
    "banner_bg":   "#1f242d",  # 頂部 banner 暗底（2026-04-28 主人嫌白底太亮，改暗灰；保留 banner_fg 給 select 用）
    "banner_fg":   "#1a1d23",  # 仍用於 selectforeground（不要動，多處引用）
    "banner_text": "#ecf0f1",  # 暗底 banner 上的亮字
    "banner_accent": "#00d4ff",
}

KNOWN_AGENTS = ["Alpha", "Beta", "Gamma", "Delta", "Epsilon", "Zeta", "Omega"]
MENTION_TOKENS = set(KNOWN_AGENTS) | {"all", "全部"}
MENTION_RE = re.compile(r"@([A-Za-z一-鿿]+)")


def parse_mentions(text):
    """從 text 抓 @Name → 回 lower-case-normalised list；支援 @Alpha @all @全部。"""
    found = []
    for m in MENTION_RE.findall(text or ""):
        if m in MENTION_TOKENS:
            found.append(m if m != "全部" else "all")
    seen = set()
    out = []
    for m in found:
        if m not in seen:
            seen.add(m)
            out.append(m)
    return out
# 靜態 fallback；本機那一列會在啟動時被 detect_local_hardware() 即時 sysctl 結果蓋過
HARDWARE = {
    "Alpha":   "M1 Mac mini · 8G / 256G",
    "Beta":    "M1 MacBook Air · 16G / 1T",
    "Gamma":   "Intel Mac mini 2012 · i7 / 16G",
    "Delta":   "主人桌上 Mac（自動偵測）",
    "Epsilon": "XeonMicroPC · i9-10900 / 64G / 512G · Win11",
    "Zeta":    "主人 RTX PC · Win11（待 onboard）",
    "Omega":   "未配置",
}

APPLE_MODEL_NAMES = {
    # Intel Mac mini（Gamma 在用 6,2）
    "Macmini6,1":      "Intel Mac mini 2012 (i5)",
    "Macmini6,2":      "Intel Mac mini 2012 (Quad i7)",
    "Macmini7,1":      "Intel Mac mini 2014",
    "Macmini8,1":      "Intel Mac mini 2018",
    # Apple Silicon 常見機型；找不到就直接顯示 model identifier
    "Macmini9,1":      "M1 Mac mini",
    "Mac14,3":         "M2 Mac mini",
    "Mac14,12":        "M2 Pro Mac mini",
    "Mac16,10":        "M4 Mac mini",
    "Mac16,11":        "M4 Pro Mac mini",
    "MacBookAir10,1":  "M1 MacBook Air",
    "Mac14,2":         "M2 MacBook Air",
    "Mac14,15":        "M2 MacBook Air 15",
    "Mac15,12":        "M3 MacBook Air",
    "Mac15,13":        "M3 MacBook Air 15",
    "Mac16,12":        "M4 MacBook Air 13",
    "Mac16,13":        "M4 MacBook Air 15",
    "MacBookPro17,1":  "M1 MacBook Pro 13",
    "MacBookPro18,1":  "M1 Pro MacBook Pro 16",
    "MacBookPro18,2":  "M1 Max MacBook Pro 16",
    "MacBookPro18,3":  "M1 Pro MacBook Pro 14",
    "MacBookPro18,4":  "M1 Max MacBook Pro 14",
    "Mac14,7":         "M2 MacBook Pro 13",
    "Mac14,5":         "M2 Max MacBook Pro 14",
    "Mac14,6":         "M2 Max MacBook Pro 16",
    "Mac15,3":         "M3 MacBook Pro 14",
    "Mac15,6":         "M3 Pro MacBook Pro 14",
    "Mac15,7":         "M3 Max MacBook Pro 14",
    "Mac15,8":         "M3 Pro MacBook Pro 16",
    "Mac16,1":         "M4 MacBook Pro 14",
    "Mac16,5":         "M4 Pro MacBook Pro 14",
    "Mac16,6":         "M4 Max MacBook Pro 16",
    "iMac21,1":        "M1 iMac",
    "Mac15,4":         "M3 iMac",
    "Mac15,5":         "M3 iMac (10-core GPU)",
    "Mac16,2":         "M4 iMac",
}


def detect_local_hardware():
    """跨平台抓本機型號 / RAM / 磁碟，回傳人類可讀字串；偵測失敗回 None。"""
    try:
        if sys.platform == "darwin":
            model_id = subprocess.check_output(["/usr/sbin/sysctl", "-n", "hw.model"],
                                               text=True, timeout=2).strip()
            memsize = int(subprocess.check_output(["/usr/sbin/sysctl", "-n", "hw.memsize"],
                                                  text=True, timeout=2).strip())
            ram_gb = memsize // (1024 ** 3)

            disk = "?"
            try:
                df = subprocess.check_output(["df", "-h", "/"], text=True, timeout=2).splitlines()
                if len(df) >= 2:
                    fields = df[1].split()
                    if len(fields) >= 2:
                        disk = fields[1].replace("Gi", "G").replace("Ti", "T")
            except Exception:
                pass

            friendly = APPLE_MODEL_NAMES.get(model_id, model_id)
            return f"{friendly} · {ram_gb}G / {disk}"

        if sys.platform == "win32":
            import ctypes
            import shutil

            class MEMORYSTATUSEX(ctypes.Structure):
                _fields_ = [
                    ("dwLength", ctypes.c_ulong),
                    ("dwMemoryLoad", ctypes.c_ulong),
                    ("ullTotalPhys", ctypes.c_ulonglong),
                    ("ullAvailPhys", ctypes.c_ulonglong),
                    ("ullTotalPageFile", ctypes.c_ulonglong),
                    ("ullAvailPageFile", ctypes.c_ulonglong),
                    ("ullTotalVirtual", ctypes.c_ulonglong),
                    ("ullAvailVirtual", ctypes.c_ulonglong),
                    ("sullAvailExtendedVirtual", ctypes.c_ulonglong),
                ]

            stat = MEMORYSTATUSEX()
            stat.dwLength = ctypes.sizeof(MEMORYSTATUSEX)
            ctypes.windll.kernel32.GlobalMemoryStatusEx(ctypes.byref(stat))
            ram_gb = stat.ullTotalPhys // (1024 ** 3)

            cpu = "?"
            try:
                # 優先 PowerShell（Win11 24H2 後 wmic 已淘汰）
                ps = subprocess.check_output(
                    ["powershell", "-NoProfile", "-Command",
                     "(Get-CimInstance Win32_Processor).Name"],
                    text=True, timeout=4, stderr=subprocess.DEVNULL).strip()
                if ps:
                    cpu = ps.splitlines()[0].strip()
            except Exception:
                try:
                    out = subprocess.check_output(
                        ["wmic", "cpu", "get", "name"],
                        text=True, timeout=4, stderr=subprocess.DEVNULL).strip().splitlines()
                    for line in out[1:]:
                        if line.strip():
                            cpu = line.strip()
                            break
                except Exception:
                    pass

            disk_gb = "?"
            try:
                total, used, free = shutil.disk_usage("C:\\")
                disk_gb = total // (1024 ** 3)
            except Exception:
                pass

            return f"{cpu} · {ram_gb}G / {disk_gb}G · Win"

        if sys.platform.startswith("linux"):
            import shutil
            cpu = "?"
            ram_gb = "?"
            try:
                with open("/proc/cpuinfo") as f:
                    for line in f:
                        if line.startswith("model name"):
                            cpu = line.split(":", 1)[1].strip()
                            break
            except Exception:
                pass
            try:
                with open("/proc/meminfo") as f:
                    for line in f:
                        if line.startswith("MemTotal:"):
                            kb = int(line.split()[1])
                            ram_gb = kb // (1024 * 1024)
                            break
            except Exception:
                pass
            disk_gb = "?"
            try:
                total, used, free = shutil.disk_usage("/")
                disk_gb = total // (1024 ** 3)
            except Exception:
                pass
            return f"{cpu} · {ram_gb}G / {disk_gb}G · Linux"
    except Exception:
        return None
    return None


def detect_dropbox_root():
    """跨平台找 PleiadesMaids Dropbox 根目錄；找不到回 None。"""
    home = Path.home()
    candidates = [
        home / "Library" / "CloudStorage" / "Dropbox" / "PleiadesMaids",  # macOS Dropbox app
        home / "Dropbox" / "PleiadesMaids",                                # Windows / Linux 預設
        home / "Dropbox (個人)" / "PleiadesMaids",
        home / "Dropbox (Personal)" / "PleiadesMaids",
    ]
    for p in candidates:
        if p.exists():
            return p
    return candidates[0]


DROPBOX_ROOT = detect_dropbox_root()
TIMELINE_PATH = DROPBOX_ROOT / "Timeline.md"
LOG_DIR = Path.home() / ".pleiadex" / "delta_dashboard"
LOG_DIR.mkdir(parents=True, exist_ok=True)


def now_iso():
    return datetime.now().astimezone().strftime("%Y-%m-%dT%H:%M:%S%z")


def now_short():
    return datetime.now().strftime("%H:%M:%S")


# ─── MQTT 後台執行緒 ─────────────────────────────────────────
class MQTTWorker:
    def __init__(self, ui_queue):
        self.ui_queue = ui_queue
        self.client = mqtt.Client(
            client_id=f"DeltaDashboard-{os.getpid()}",
            clean_session=True,
        )
        self.client.will_set(
            f"pleiadex/agents/{AGENT}/status",
            payload=json.dumps({"agent": AGENT, "status": "offline_lwt", "ts": now_iso()}),
            qos=1, retain=True,
        )
        self.client.on_connect = self._on_connect
        self.client.on_message = self._on_message
        self.client.on_disconnect = self._on_disconnect
        self.connected = False

    def _on_connect(self, client, userdata, flags, rc):
        if rc == 0:
            self.connected = True
            self.ui_queue.put(("system", f"connected to {BROKER}:{PORT}"))
            client.subscribe([
                (f"pleiadex/agents/{AGENT}/inbox", 1),
                ("pleiadex/broadcast", 1),
                ("pleiadex/agents/+/status", 1),
                ("pleiadex/agents/+/hardware", 1),
                ("pleiadex/system/+", 1),
                ("pleiadex/agents/Xeon/outbox", 1),  # 主人 Xeon 廣播 channel：主人講啥大家直接收
                ("pleiadex/agents/+/inbox", 0),  # 訂全部 inbox 看誰傳給誰（QoS 0 不重要 inbox 不漏聽）
            ])
            self._publish_status("online")
            self._publish_hardware()
        else:
            self.ui_queue.put(("system", f"connect failed rc={rc}"))

    def _on_disconnect(self, client, userdata, rc):
        self.connected = False
        self.ui_queue.put(("system", f"disconnected rc={rc}"))

    def _on_message(self, client, userdata, msg):
        try:
            payload = msg.payload.decode("utf-8")
            data = json.loads(payload)
        except Exception:
            self.ui_queue.put(("malformed", msg.topic, repr(msg.payload)))
            return

        topic = msg.topic
        if topic.startswith("pleiadex/agents/") and topic.endswith("/status"):
            agent = topic.split("/")[2]
            self.ui_queue.put(("status", agent, data))
        elif topic.startswith("pleiadex/agents/") and topic.endswith("/hardware"):
            agent = topic.split("/")[2]
            self.ui_queue.put(("hardware", agent, data))
        elif topic == "pleiadex/broadcast":
            if data.get("from") == AGENT:
                return
            self.ui_queue.put(("broadcast", data))
        elif topic == f"pleiadex/agents/{AGENT}/inbox":
            self.ui_queue.put(("inbox", data))
        elif topic.startswith("pleiadex/system/"):
            self.ui_queue.put(("system_event", topic, data))
        else:
            self.ui_queue.put(("other", topic, data))

    def _publish_status(self, status):
        self.client.publish(
            f"pleiadex/agents/{AGENT}/status",
            json.dumps({"agent": AGENT, "status": status, "ts": now_iso(), "pid": os.getpid()}),
            qos=1, retain=True,
        )

    def _publish_hardware(self):
        """retained：把本機 sysctl 偵測到的硬體資訊發到 MQTT，給其他 dashboard 看真實值。"""
        hw = HARDWARE.get(AGENT, "?")
        self.client.publish(
            f"pleiadex/agents/{AGENT}/hardware",
            json.dumps({
                "agent": AGENT,
                "hardware": hw,
                "ts": now_iso(),
                "platform": sys.platform,
            }, ensure_ascii=False),
            qos=1, retain=True,
        )

    def heartbeat_loop(self):
        while True:
            time.sleep(30)
            if self.connected:
                self._publish_status("online")

    def publish_message(self, target, text, mentions=None):
        msg_id = str(uuid.uuid4())
        env = {
            "from": AGENT,
            "to": target,
            "text": text,
            "ts": now_iso(),
            "msg_id": msg_id,
            "mentions": list(mentions) if mentions else [],
        }
        topic = "pleiadex/broadcast" if target == "broadcast" else f"pleiadex/agents/{target}/inbox"
        self.client.publish(topic, json.dumps(env, ensure_ascii=False), qos=1)
        return topic, msg_id

    def start(self):
        try:
            self.client.connect(BROKER, PORT, keepalive=60)
        except OSError as e:
            print(f"[dashboard] broker offline: {BROKER}:{PORT} ({e}); GUI will run in offline mode and reconnect in background")
            try:
                self.client.connect_async(BROKER, PORT, keepalive=60)
            except Exception:
                pass
        self.client.loop_start()
        threading.Thread(target=self.heartbeat_loop, daemon=True).start()

    def stop(self):
        try:
            self._publish_status("offline_idle")
            time.sleep(0.3)
        finally:
            self.client.loop_stop()
            self.client.disconnect()


# ─── 主視窗 ─────────────────────────────────────────────────
class DeltaDashboard:
    STATUS_COLORS = {
        "online":       "#2ecc71",
        "offline_idle": "#f39c12",
        "offline_lwt":  "#e74c3c",
        "unknown":      "#95a5a6",
    }

    def __init__(self, root):
        self.root = root
        self.root.title(f"PleiadeX Dashboard — {AGENT}")
        self.root.geometry(f"{DASHBOARD_WIDTH}x{DASHBOARD_HEIGHT}")
        self.root.minsize(DASHBOARD_WIDTH, DASHBOARD_HEIGHT)
        self.root.configure(bg=PALETTE["bg"])

        self.ui_queue = queue.Queue()
        self.worker = MQTTWorker(self.ui_queue)
        self.agent_status = {a: {"status": "unknown", "ts": None, "pid": None} for a in KNOWN_AGENTS}
        self.agent_status[AGENT]["status"] = "online"

        self._build_banner()
        self._build_status_bar()
        self._build_notebook()
        self._build_statusline()

        self.worker.start()
        self.root.after(100, self._poll_queue)
        self.root.after(1000, self._tick_status_freshness)
        self.root.after_idle(self._stabilize_tab_geometry)
        self.root.protocol("WM_DELETE_WINDOW", self._on_close)

    # ─── 元件 ───────────────────────────────────────────
    def _build_banner(self):
        """頂部暗底亮字 logo banner（2026-04-28 主人嫌白底太亮改暗灰）。"""
        p = PALETTE
        banner = tk.Frame(self.root, bg=p["banner_bg"], height=56)
        banner.pack(fill=tk.X, side=tk.TOP)
        banner.pack_propagate(False)

        # 左：logo 主標
        title_box = tk.Frame(banner, bg=p["banner_bg"])
        title_box.pack(side=tk.LEFT, padx=18, pady=8)
        tk.Label(title_box, text="PLEIADEX SYSTEM",
                 bg=p["banner_bg"], fg=p["banner_text"],
                 font=("Helvetica", 18, "bold")).pack(side=tk.LEFT)
        tk.Label(title_box, text="  - 昴宿星團 MQTT 中控",
                 bg=p["banner_bg"], fg=p["banner_text"],
                 font=("Helvetica", 13)).pack(side=tk.LEFT, padx=(2, 0))
        tk.Label(title_box, text="  v1.0.0",
                 bg=p["banner_bg"], fg=p["fg_dim"],
                 font=("Helvetica", 11)).pack(side=tk.LEFT, padx=(8, 0))

        # 右：本機 agent 識別卡（強調青藍底；底色亮對比深字保留）
        ident = tk.Frame(banner, bg=p["banner_accent"])
        ident.pack(side=tk.RIGHT, padx=18, pady=10)
        tk.Label(ident, text=f"  本機：{AGENT}  ",
                 bg=p["banner_accent"], fg=p["banner_fg"],
                 font=("Helvetica", 13, "bold")).pack(padx=8, pady=4)

        # 底部 1px 強調 bar
        accent_bar = tk.Frame(self.root, bg=p["accent"], height=2)
        accent_bar.pack(fill=tk.X, side=tk.TOP)

    def _build_status_bar(self):
        p = PALETTE
        bar = tk.Frame(self.root, bg=p["panel"], height=44)
        bar.pack(fill=tk.X, side=tk.TOP)
        bar.pack_propagate(False)

        tk.Label(bar, text="● 內線狀態", bg=p["panel"], fg=p["accent"],
                 font=("Helvetica", 12, "bold")).pack(side=tk.LEFT, padx=14)

        self.status_lights = {}
        for agent in KNOWN_AGENTS:
            container = tk.Frame(bar, bg=p["panel"])
            container.pack(side=tk.LEFT, padx=6)
            light = tk.Label(container, text="●", font=("Helvetica", 18),
                             bg=p["panel"], fg=self.STATUS_COLORS["unknown"])
            light.pack(side=tk.LEFT)
            label = tk.Label(container, text=agent, bg=p["panel"], fg=p["fg"],
                             font=("Helvetica", 11))
            label.pack(side=tk.LEFT)
            self.status_lights[agent] = (light, label)

        self.broker_label = tk.Label(bar, text=f"broker: {BROKER}:{PORT}",
                                     bg=p["panel"], fg=p["fg_dim"],
                                     font=("Helvetica", 10))
        self.broker_label.pack(side=tk.RIGHT, padx=14)

    def _build_notebook(self):
        self.nb = ttk.Notebook(self.root, width=NOTEBOOK_WIDTH, height=NOTEBOOK_HEIGHT)
        self.nb.pack(fill=tk.BOTH, expand=True, padx=4, pady=4)
        self.nb.pack_propagate(False)
        # 切頁時：先同步 stabilize（卡住 geometry），再 after_idle 二次保險（macOS Tk 兩次 reflow）
        self.nb.bind("<<NotebookTabChanged>>", self._on_tab_changed)

        self._build_chat_tab()
        self._build_system_tab()
        self._build_schedule_tab()
        self._build_command_tab()

    def _make_tab(self, title):
        """Create a fixed-request-size Notebook page.

        macOS Tk can recompute a toplevel's requested size from the selected
        Notebook page.  Keeping every tab at the same requested dimensions
        prevents the whole dashboard from shrinking when switching to a tab
        with less content.
        """
        tab = ttk.Frame(self.nb, width=NOTEBOOK_WIDTH, height=NOTEBOOK_HEIGHT)
        tab.pack_propagate(False)
        tab.grid_propagate(False)
        self.nb.add(tab, text=title)
        return tab

    def _on_tab_changed(self, _event):
        """切頁回調：同步鎖 geometry → 強制 update_idletasks → after_idle 二次保險。

        2026-04-28 修：原本只 after_idle 一次，主人在 Beta 機切頁仍看到劇變。
        macOS Tk 對 ttk.Notebook 切頁會 reflow toplevel reqsize 兩次（select 一次、
        layout 一次），單次 stabilize 跟不上。
        """
        self._stabilize_tab_geometry()
        self.root.update_idletasks()
        self.root.after_idle(self._stabilize_tab_geometry)

    def _stabilize_tab_geometry(self):
        self.root.minsize(DASHBOARD_WIDTH, DASHBOARD_HEIGHT)
        # 強制鎖回固定尺寸（不再「比 minsize 小才放大」單向修正，雙向都鎖）
        cur_w = self.root.winfo_width()
        cur_h = self.root.winfo_height()
        if cur_w != DASHBOARD_WIDTH or cur_h != DASHBOARD_HEIGHT:
            self.root.geometry(f"{DASHBOARD_WIDTH}x{DASHBOARD_HEIGHT}")

    def _build_statusline(self):
        p = PALETTE
        self.statusline = tk.Label(self.root, text=f"[{now_short()}] booting…",
                                   bg=p["panel_alt"], fg=p["fg"],
                                   font=("Menlo", 10), anchor=tk.W,
                                   padx=12, pady=4)
        self.statusline.pack(fill=tk.X, side=tk.BOTTOM)

    # ─── Tab 1: 聊天 ────────────────────────────────────
    def _build_chat_tab(self):
        tab = self._make_tab("💬 聊天")

        paned = ttk.PanedWindow(tab, orient=tk.HORIZONTAL)
        paned.pack(fill=tk.BOTH, expand=True)

        # 左：辦公室大廳
        left = ttk.LabelFrame(paned, text="辦公室大廳（pleiadex/broadcast）")
        paned.add(left, weight=3)

        p = PALETTE
        self.lobby_text = scrolledtext.ScrolledText(
            left, wrap=tk.WORD, font=("Menlo", 11), state=tk.DISABLED,
            bg=p["panel"], fg=p["fg"], insertbackground=p["accent"],
            selectbackground=p["accent"], selectforeground=p["banner_fg"],
            borderwidth=0, relief=tk.FLAT,
        )
        self.lobby_text.pack(fill=tk.BOTH, expand=True, padx=4, pady=4)
        self._tag_setup(self.lobby_text)

        # 右：上=快速跟 Alpha + 下=下發文（兩區 1:1，用 grid uniform，2026-04-28 主人指示）
        right = ttk.Frame(paned)
        paned.add(right, weight=2)
        right.rowconfigure(0, weight=1, uniform="half")
        right.rowconfigure(1, weight=1, uniform="half")
        right.columnconfigure(0, weight=1)

        alpha_frame = ttk.LabelFrame(right, text="快速跟 Alpha 交談（DM）")
        alpha_frame.grid(row=0, column=0, sticky="nsew", padx=4, pady=(4, 2))

        self.alpha_text = scrolledtext.ScrolledText(
            alpha_frame, wrap=tk.WORD, font=("Menlo", 11), state=tk.DISABLED,
            bg=p["panel"], fg=p["fg"], insertbackground=p["accent"],
            selectbackground=p["accent"], selectforeground=p["banner_fg"],
            borderwidth=0, relief=tk.FLAT,
        )
        self.alpha_text.pack(fill=tk.BOTH, expand=True, padx=4, pady=4)
        self._tag_setup(self.alpha_text)

        alpha_send = ttk.Frame(alpha_frame)
        alpha_send.pack(fill=tk.X, padx=4, pady=(0, 4))
        self.alpha_entry = ttk.Entry(alpha_send)
        self.alpha_entry.pack(side=tk.LEFT, fill=tk.X, expand=True, padx=(0, 4))
        self.alpha_entry.bind("<Return>", lambda e: self._send_to_alpha())
        ttk.Button(alpha_send, text="→ Alpha", command=self._send_to_alpha).pack(side=tk.RIGHT)

        # 下：通用發文（可選 broadcast / 任一 agent）— 與 alpha_frame 1:1
        compose = ttk.LabelFrame(right, text="下發文（串口模式）")
        compose.grid(row=1, column=0, sticky="nsew", padx=4, pady=(2, 4))

        target_row = ttk.Frame(compose)
        target_row.pack(fill=tk.X, padx=4, pady=2)
        ttk.Label(target_row, text="收件對象：").pack(side=tk.LEFT)
        self.compose_target = ttk.Combobox(
            target_row, state="readonly",
            values=["broadcast"] + [a for a in KNOWN_AGENTS if a != AGENT],
            width=14,
        )
        self.compose_target.current(0)
        self.compose_target.pack(side=tk.LEFT, padx=4)

        self.compose_entry = scrolledtext.ScrolledText(
            compose, height=4, wrap=tk.WORD, font=("Menlo", 11),
            bg=p["panel_alt"], fg=p["fg"], insertbackground=p["accent"],
            selectbackground=p["accent"], selectforeground=p["banner_fg"],
            borderwidth=0, relief=tk.FLAT,
        )
        self.compose_entry.pack(fill=tk.BOTH, expand=True, padx=4, pady=2)
        self.compose_entry.bind("<Control-Return>", lambda e: self._send_compose())
        self.compose_entry.bind("<Command-Return>", lambda e: self._send_compose())
        self.compose_entry.bind("<KeyRelease>", self._on_compose_keyrelease)

        self._mention_popup = None

        send_row = ttk.Frame(compose)
        send_row.pack(fill=tk.X, padx=4, pady=2)
        ttk.Label(send_row, text=f"↩ Cmd/Ctrl+Enter 送出 · 打 @ 跳點名選單 · from={AGENT}",
                  foreground=PALETTE["fg_dim"], background=PALETTE["panel"]).pack(side=tk.LEFT)
        ttk.Button(send_row, text="送出", command=self._send_compose).pack(side=tk.RIGHT)

    def _on_compose_keyrelease(self, event):
        """打 @ 觸發 popup；popup 已開時上下鍵 / Enter 在 popup handler 處理。"""
        if event.keysym in ("Up", "Down", "Return", "Escape"):
            return
        try:
            cursor = self.compose_entry.index(tk.INSERT)
            line_start = self.compose_entry.index(f"{cursor} linestart")
            before = self.compose_entry.get(line_start, cursor)
        except tk.TclError:
            return
        m = re.search(r"@([A-Za-z一-鿿]*)$", before)
        if m:
            prefix = m.group(1)
            self._show_mention_popup(prefix)
        else:
            self._hide_mention_popup()

    def _show_mention_popup(self, prefix=""):
        candidates = [a for a in KNOWN_AGENTS if a != AGENT and a.lower().startswith(prefix.lower())]
        candidates += [c for c in ("all", "全部") if c.startswith(prefix.lower())]
        if not candidates:
            self._hide_mention_popup()
            return
        if self._mention_popup is None:
            popup = tk.Toplevel(self.root)
            popup.wm_overrideredirect(True)
            popup.attributes("-topmost", True)
            lb = tk.Listbox(popup, height=min(len(candidates), 7),
                            bg=PALETTE["panel_alt"], fg=PALETTE["fg"],
                            selectbackground=PALETTE["accent"],
                            selectforeground=PALETTE["bg"],
                            borderwidth=1, relief=tk.SOLID, font=("Menlo", 11))
            lb.pack()
            self._mention_popup = (popup, lb)
            self.compose_entry.bind("<Up>", self._mention_popup_nav, add="+")
            self.compose_entry.bind("<Down>", self._mention_popup_nav, add="+")
            self.compose_entry.bind("<Return>", self._mention_popup_pick, add="+")
            self.compose_entry.bind("<Escape>", lambda e: self._hide_mention_popup(), add="+")
        popup, lb = self._mention_popup
        lb.delete(0, tk.END)
        for c in candidates:
            lb.insert(tk.END, c)
        lb.selection_clear(0, tk.END)
        lb.selection_set(0)
        try:
            x, y, _, h = self.compose_entry.bbox(tk.INSERT)
            ax = self.compose_entry.winfo_rootx() + x
            ay = self.compose_entry.winfo_rooty() + y + h + 2
            popup.geometry(f"+{ax}+{ay}")
        except (tk.TclError, TypeError):
            pass

    def _hide_mention_popup(self):
        if self._mention_popup is not None:
            popup, _ = self._mention_popup
            popup.destroy()
            self._mention_popup = None

    def _mention_popup_nav(self, event):
        if self._mention_popup is None:
            return
        _, lb = self._mention_popup
        cur = lb.curselection()
        idx = cur[0] if cur else 0
        size = lb.size()
        if event.keysym == "Down":
            idx = (idx + 1) % size
        elif event.keysym == "Up":
            idx = (idx - 1) % size
        lb.selection_clear(0, tk.END)
        lb.selection_set(idx)
        return "break"

    def _mention_popup_pick(self, event):
        if self._mention_popup is None:
            return None
        _, lb = self._mention_popup
        cur = lb.curselection()
        if not cur:
            self._hide_mention_popup()
            return None
        pick = lb.get(cur[0])
        cursor = self.compose_entry.index(tk.INSERT)
        line_start = self.compose_entry.index(f"{cursor} linestart")
        before = self.compose_entry.get(line_start, cursor)
        m = re.search(r"@([A-Za-z一-鿿]*)$", before)
        if m:
            replace_from = self.compose_entry.index(f"{cursor} - {len(m.group(1))} chars")
            self.compose_entry.delete(replace_from, cursor)
            self.compose_entry.insert(replace_from, pick + " ")
        self._hide_mention_popup()
        return "break"

    def _tag_setup(self, txt):
        p = PALETTE
        txt.tag_configure("ts",     foreground=p["fg_dim"])
        txt.tag_configure("from",   foreground=p["accent"], font=("Menlo", 11, "bold"))
        txt.tag_configure("system", foreground=p["success"], font=("Menlo", 11, "italic"))
        txt.tag_configure("alert",  foreground=p["danger"], font=("Menlo", 11, "bold"))
        txt.tag_configure("mention_from", foreground=p["danger"], font=("Menlo", 11, "bold"))
        txt.tag_configure("mention_text", foreground=p["fg"], background="#4a2530")

    def _append_chat(self, widget, sender, text, ts=None, kind=None):
        widget.configure(state=tk.NORMAL)
        widget.insert(tk.END, f"[{ts or now_short()}] ", "ts")
        if kind == "system":
            widget.insert(tk.END, f"⚙ {text}\n", "system")
        elif kind == "alert":
            widget.insert(tk.END, f"⚠ {sender}: {text}\n", "alert")
        elif kind == "mention":
            widget.insert(tk.END, f"🔔 {sender}: ", "mention_from")
            widget.insert(tk.END, f"{text}\n", "mention_text")
        else:
            widget.insert(tk.END, f"{sender}: ", "from")
            widget.insert(tk.END, f"{text}\n")
        widget.configure(state=tk.DISABLED)
        widget.see(tk.END)

    def _send_to_alpha(self):
        text = self.alpha_entry.get().strip()
        if not text:
            return
        topic, msg_id = self.worker.publish_message("Alpha", text)
        self._append_chat(self.alpha_text, AGENT, text, kind=None)
        self.alpha_entry.delete(0, tk.END)

    def _send_compose(self):
        text = self.compose_entry.get("1.0", tk.END).strip()
        if not text:
            return
        target = self.compose_target.get()
        mentions = parse_mentions(text) if target == "broadcast" else None
        topic, msg_id = self.worker.publish_message(target, text, mentions=mentions)
        if target == "broadcast":
            mention_tag = f"  [@→ {', '.join(mentions)}]" if mentions else ""
            self._append_chat(self.lobby_text, AGENT, text + mention_tag)
        else:
            self._append_chat(self.lobby_text, AGENT, f"→ {target}: {text}", kind=None)
        self.compose_entry.delete("1.0", tk.END)

    # ─── Tab 2: 系統狀態 ─────────────────────────────────
    def _build_system_tab(self):
        tab = self._make_tab("🖥 系統")

        cols = ("agent", "hardware", "status", "pid", "ts", "age")
        self.system_tree = ttk.Treeview(tab, columns=cols, show="headings", height=12)
        for col, title, width in [
            ("agent",    "Agent",      100),
            ("hardware", "主機描述",   320),
            ("status",   "狀態",       130),
            ("pid",      "PID",         80),
            ("ts",       "最後心跳",   220),
            ("age",      "活躍度",     120),
        ]:
            self.system_tree.heading(col, text=title)
            self.system_tree.column(col, width=width, anchor=tk.W)
        self.system_tree.pack(fill=tk.BOTH, expand=True, padx=8, pady=8)

        for agent in KNOWN_AGENTS:
            self.system_tree.insert("", tk.END, iid=agent, values=(
                agent, HARDWARE.get(agent, "?"), "unknown", "-", "-", "-",
            ))

        info = ttk.LabelFrame(tab, text="Broker 與 Dashboard")
        info.pack(fill=tk.X, padx=8, pady=(0, 8))
        p = PALETTE
        self.broker_info = tk.Label(info, text="-", anchor=tk.W, justify=tk.LEFT,
                                    font=("Menlo", 10),
                                    bg=p["panel"], fg=p["fg"])
        self.broker_info.pack(fill=tk.X, padx=8, pady=4)

    def _refresh_system_tab(self):
        for agent in KNOWN_AGENTS:
            s = self.agent_status[agent]
            ts = s["ts"] or "-"
            age = "-"
            if s["ts"]:
                try:
                    delta = datetime.now().astimezone() - datetime.fromisoformat(s["ts"])
                    age = f"{int(delta.total_seconds())}s ago"
                except Exception:
                    pass
            self.system_tree.item(agent, values=(
                agent, HARDWARE.get(agent, "?"), s["status"], s["pid"] or "-", ts, age,
            ))

        self.broker_info.config(text=(
            f"broker:        {BROKER}:{PORT}\n"
            f"client_id:     DeltaDashboard-{os.getpid()}\n"
            f"connected:     {self.worker.connected}\n"
            f"last refresh:  {now_iso()}"
        ))

    # ─── Tab 3: 日課表 ──────────────────────────────────
    def _build_schedule_tab(self):
        tab = self._make_tab("📅 日課表")

        top = ttk.Frame(tab)
        top.pack(fill=tk.X, padx=8, pady=4)
        ttk.Label(top, text=f"來源：{TIMELINE_PATH}",
                  foreground=PALETTE["fg_dim"]).pack(side=tk.LEFT)

        ttk.Label(top, text="　顯示：").pack(side=tk.LEFT, padx=(16, 2))
        self.schedule_filter = ttk.Combobox(
            top, state="readonly",
            values=["全部"] + KNOWN_AGENTS,
            width=10,
        )
        self.schedule_filter.current(0)
        self.schedule_filter.pack(side=tk.LEFT)
        self.schedule_filter.bind("<<ComboboxSelected>>", lambda e: self._reload_schedule())

        ttk.Button(top, text="↻ 重新讀取", command=self._reload_schedule).pack(side=tk.RIGHT)

        cols = ("time", "event", "executor", "weekdays", "source", "note")
        self.schedule_tree = ttk.Treeview(tab, columns=cols, show="headings", height=20)
        for col, title, width in [
            ("time",     "時間",     130),
            ("event",    "事件",     320),
            ("executor", "執行者",   180),
            ("weekdays", "適用星期", 100),
            ("source",   "來源",     220),
            ("note",     "備註",     280),
        ]:
            self.schedule_tree.heading(col, text=title)
            self.schedule_tree.column(col, width=width, anchor=tk.W)
        self.schedule_tree.pack(fill=tk.BOTH, expand=True, padx=8, pady=8)

        self._reload_schedule()

    def _reload_schedule(self):
        for item in self.schedule_tree.get_children():
            self.schedule_tree.delete(item)
        if not TIMELINE_PATH.exists():
            self.schedule_tree.insert("", tk.END, values=("-", f"找不到 {TIMELINE_PATH}", "-", "-", "-", "-"))
            return
        try:
            text = TIMELINE_PATH.read_text(encoding="utf-8")
        except Exception as e:
            self.schedule_tree.insert("", tk.END, values=("-", f"讀取失敗: {e}", "-", "-", "-", "-"))
            return

        in_table = False
        rows = []
        for line in text.splitlines():
            if line.startswith("| 時間 | 事件 |"):
                in_table = True
                continue
            if not in_table:
                continue
            if line.startswith("|------"):
                continue
            if not line.startswith("|"):
                if rows:
                    break
                continue
            cells = [c.strip() for c in line.strip("|").split("|")]
            if len(cells) >= 6:
                rows.append(cells[:6])

        chosen = self.schedule_filter.get() if hasattr(self, "schedule_filter") else "全部"
        shown = 0
        for r in rows:
            if chosen != "全部":
                # 用 executor + 事件 + 備註 + 來源四欄合併判斷，命中關鍵字才顯示
                blob = " ".join(r)
                if chosen.lower() not in blob.lower():
                    continue
            self.schedule_tree.insert("", tk.END, values=tuple(r))
            shown += 1
        if shown == 0:
            self.schedule_tree.insert("", tk.END, values=(
                "-", f"（{chosen} 沒有匹配的排程列）", "-", "-", "-", "-",
            ))

    # ─── Tab 4: 快速指令 ────────────────────────────────
    def _build_command_tab(self):
        tab = self._make_tab("⚡ 指令")

        top = ttk.LabelFrame(tab, text="目標選擇")
        top.pack(fill=tk.X, padx=8, pady=8)

        ttk.Label(top, text="送往：").pack(side=tk.LEFT, padx=4)
        self.cmd_target = ttk.Combobox(
            top, state="readonly",
            values=["broadcast"] + [a for a in KNOWN_AGENTS if a != AGENT],
            width=18,
        )
        self.cmd_target.current(1 if len(KNOWN_AGENTS) > 1 else 0)
        self.cmd_target.pack(side=tk.LEFT, padx=4)

        # 快捷按鈕區（改大按鈕修 ttk.Button 多行文字破圖；用 tk.Button 控字型 + 固定尺寸）
        buttons = ttk.LabelFrame(tab, text="快速指令（送 /cc 開頭，主人專屬遠端控制）")
        buttons.pack(fill=tk.X, padx=8, pady=4)

        p = PALETTE
        commands = [
            ("🧹", "/cc clear",   "清空對方 context（先確認）", p["danger"]),
            ("📦", "/cc compact", "壓縮 context",                p["info"]),
            ("📊", "/cc status",  "回報狀態 / context 使用率",   p["success"]),
            ("❓", "/cc help",    "列可用指令",                  p["fg_dim"]),
            ("🔄", "/cc restart", "重啟 tmux session",           p["warning"]),
            ("🧠", "/cc memory",  "整理共同記憶",                p["purple"]),
        ]
        # 跨平台中文字型；Windows 缺 PingFang 會 fallback 到 Microsoft JhengHei
        title_font = ("PingFang TC", 15, "bold") if sys.platform == "darwin" \
                     else ("Microsoft JhengHei UI", 13, "bold")
        desc_font = ("PingFang TC", 11) if sys.platform == "darwin" \
                    else ("Microsoft JhengHei UI", 10)

        grid = ttk.Frame(buttons)
        grid.pack(fill=tk.X, padx=8, pady=8)
        for i, (icon, cmd, desc, color) in enumerate(commands):
            row, col = divmod(i, 3)
            cell = tk.Frame(grid, bd=0, highlightthickness=1,
                            highlightbackground=p["border"],
                            highlightcolor=color,
                            bg=p["panel_alt"], cursor="hand2",
                            padx=14, pady=12)
            cell.grid(row=row, column=col, sticky="nsew", padx=6, pady=6)
            title = tk.Label(cell, text=f"{icon}  {cmd}",
                             font=title_font, fg=color, bg=p["panel_alt"])
            title.pack(anchor="w")
            sub = tk.Label(cell, text=desc, font=desc_font,
                           fg=p["fg"], bg=p["panel_alt"],
                           wraplength=220, justify="left")
            sub.pack(anchor="w", pady=(4, 0))
            # 整個 cell 點擊都觸發；hover 時 cell + 兩個 label bg 一起變色
            cell_widgets = (cell, title, sub)
            def _hover(_e, ws=cell_widgets, bg=p["panel_hover"]):
                for w in ws:
                    w.config(bg=bg)
            def _leave(_e, ws=cell_widgets, bg=p["panel_alt"]):
                for w in ws:
                    w.config(bg=bg)
            for w in cell_widgets:
                w.bind("<Button-1>", lambda e, c=cmd: self._send_cc(c))
                w.bind("<Enter>", _hover)
                w.bind("<Leave>", _leave)
        for c in range(3):
            grid.columnconfigure(c, weight=1, uniform="cmdbtn")

        # 自訂指令
        custom = ttk.LabelFrame(tab, text="自訂指令")
        custom.pack(fill=tk.X, padx=8, pady=4)
        self.custom_entry = ttk.Entry(custom)
        self.custom_entry.pack(side=tk.LEFT, fill=tk.X, expand=True, padx=4, pady=4)
        self.custom_entry.bind("<Return>", lambda e: self._send_cc(self.custom_entry.get().strip()))
        ttk.Button(custom, text="送出", command=lambda: self._send_cc(self.custom_entry.get().strip())).pack(side=tk.RIGHT, padx=4)

        # 歷史
        history = ttk.LabelFrame(tab, text="送出歷史")
        history.pack(fill=tk.BOTH, expand=True, padx=8, pady=8)
        self.cmd_history = scrolledtext.ScrolledText(
            history, wrap=tk.WORD, font=("Menlo", 10),
            state=tk.DISABLED, height=10,
            bg=p["panel"], fg=p["fg"], insertbackground=p["accent"],
            selectbackground=p["accent"], selectforeground=p["banner_fg"],
            borderwidth=0, relief=tk.FLAT,
        )
        self.cmd_history.pack(fill=tk.BOTH, expand=True, padx=4, pady=4)

    def _send_cc(self, cmd):
        if not cmd:
            return
        if cmd.startswith("/cc clear") or cmd.startswith("/cc restart"):
            if not messagebox.askyesno("確認", f"確定要送破壞性指令？\n\n{cmd}\n→ {self.cmd_target.get()}"):
                return
        target = self.cmd_target.get()
        topic, msg_id = self.worker.publish_message(target, cmd)
        self.cmd_history.configure(state=tk.NORMAL)
        self.cmd_history.insert(tk.END, f"[{now_short()}] → {target}: {cmd}  (msg_id={msg_id[:8]})\n")
        self.cmd_history.configure(state=tk.DISABLED)
        self.cmd_history.see(tk.END)
        if hasattr(self, "custom_entry"):
            self.custom_entry.delete(0, tk.END)

    # ─── 訊息分派 ───────────────────────────────────────
    def _poll_queue(self):
        try:
            while True:
                item = self.ui_queue.get_nowait()
                self._handle_event(item)
        except queue.Empty:
            pass
        self.root.after(100, self._poll_queue)

    def _handle_event(self, item):
        kind = item[0]
        if kind == "system":
            self._set_statusline(item[1])
            self._append_chat(self.lobby_text, "system", item[1], kind="system")
        elif kind == "broadcast":
            data = item[1]
            mentions = data.get("mentions") or []
            self_mentioned = (AGENT in mentions) or ("all" in mentions)
            chat_kind = "mention" if self_mentioned else None
            sender = data.get("from", "?")
            text = data.get("text", "")
            if mentions:
                text = f"{text}  [@→ {', '.join(mentions)}]"
            self._append_chat(self.lobby_text, sender, text,
                              ts=self._fmt_ts(data.get("ts")), kind=chat_kind)
            if self_mentioned:
                self._set_statusline(f"🔔 {sender} @ 你了：{data.get('text', '')[:40]}")
        elif kind == "inbox":
            data = item[1]
            sender = data.get("from", "?")
            target_widget = self.alpha_text if sender == "Alpha" else self.lobby_text
            self._append_chat(target_widget, sender, data.get("text", ""),
                              ts=self._fmt_ts(data.get("ts")))
        elif kind == "status":
            agent, data = item[1], item[2]
            if agent in self.agent_status:
                self.agent_status[agent].update({
                    "status": data.get("status", "unknown"),
                    "ts": data.get("ts"),
                    "pid": data.get("pid"),
                })
                self._refresh_status_lights()
                self._refresh_system_tab()
        elif kind == "hardware":
            agent, data = item[1], item[2]
            hw = data.get("hardware")
            if agent in HARDWARE and hw:
                HARDWARE[agent] = hw
                self._refresh_system_tab()
                self._set_statusline(f"硬體更新：{agent} = {hw}")
        elif kind == "system_event":
            topic, data = item[1], item[2]
            self._append_chat(self.lobby_text, "system", f"{topic} {data.get('text', json.dumps(data, ensure_ascii=False))}",
                              kind="system")
        elif kind == "malformed":
            topic, raw = item[1], item[2]
            self._append_chat(self.lobby_text, "system", f"malformed on {topic}: {raw}", kind="alert")

    def _refresh_status_lights(self):
        for agent in KNOWN_AGENTS:
            s = self.agent_status[agent]["status"]
            color = self.STATUS_COLORS.get(s, self.STATUS_COLORS["unknown"])
            light, label = self.status_lights[agent]
            light.config(fg=color)

    def _tick_status_freshness(self):
        for agent in KNOWN_AGENTS:
            s = self.agent_status[agent]
            if s["ts"] and s["status"] == "online":
                try:
                    delta = datetime.now().astimezone() - datetime.fromisoformat(s["ts"])
                    if delta > timedelta(seconds=120):
                        self.agent_status[agent]["status"] = "offline_idle"
                except Exception:
                    pass
        self._refresh_status_lights()
        self._refresh_system_tab()
        self.root.after(5000, self._tick_status_freshness)

    def _set_statusline(self, msg):
        self.statusline.config(text=f"[{now_short()}] {msg}")

    def _fmt_ts(self, ts):
        if not ts:
            return None
        try:
            return datetime.fromisoformat(ts).strftime("%H:%M:%S")
        except Exception:
            return ts

    # ─── 結束 ───────────────────────────────────────────
    def _on_close(self):
        try:
            self.worker.stop()
        except Exception:
            pass
        self.root.destroy()


def apply_pleiadex_theme(root):
    """套用 PleiadeX 暗色主題到所有 ttk widget。
    用 'clam' theme 為基底（最容易客製化），統一拉色票成 dark theme。"""
    root.configure(bg=PALETTE["bg"])
    style = ttk.Style()
    try:
        style.theme_use("clam")
    except Exception:
        pass

    p = PALETTE
    # 基本 Frame / Label
    style.configure("TFrame", background=p["bg"])
    style.configure("Panel.TFrame", background=p["panel"])
    style.configure("PanelAlt.TFrame", background=p["panel_alt"])

    style.configure("TLabel", background=p["bg"], foreground=p["fg"])
    style.configure("Panel.TLabel", background=p["panel"], foreground=p["fg"])
    style.configure("Dim.TLabel", background=p["bg"], foreground=p["fg_dim"])

    # LabelFrame：用面板背景 + 標題列加色 bar 風格
    style.configure("TLabelframe", background=p["panel"], borderwidth=1,
                    relief="solid", bordercolor=p["border"])
    style.configure("TLabelframe.Label", background=p["panel"],
                    foreground=p["accent"], font=("Helvetica", 11, "bold"))

    # Notebook
    style.configure("TNotebook", background=p["bg"], borderwidth=0)
    style.configure("TNotebook.Tab", background=p["panel"],
                    foreground=p["fg_dim"], padding=(20, 10),
                    font=("Helvetica", 12, "bold"))
    style.map("TNotebook.Tab",
              background=[("selected", p["panel_alt"])],
              foreground=[("selected", p["accent"])])

    # ttk.Button 暗色（Tab 4 已用 tk.Frame 自繪，這裡只影響其它 ttk.Button）
    style.configure("TButton", background=p["panel_alt"], foreground=p["fg"],
                    borderwidth=1, focusthickness=0, padding=8,
                    font=("Helvetica", 11))
    style.map("TButton",
              background=[("active", p["panel_hover"]), ("pressed", p["accent"])],
              foreground=[("pressed", p["banner_fg"])])

    # Treeview
    style.configure("Treeview", background=p["panel"], foreground=p["fg"],
                    fieldbackground=p["panel"], borderwidth=0,
                    rowheight=26, font=("Helvetica", 11))
    style.configure("Treeview.Heading", background=p["panel_alt"],
                    foreground=p["accent"], borderwidth=0,
                    font=("Helvetica", 11, "bold"))
    style.map("Treeview",
              background=[("selected", p["accent"])],
              foreground=[("selected", p["banner_fg"])])
    style.map("Treeview.Heading", background=[("active", p["panel_hover"])])

    # Combobox
    style.configure("TCombobox", fieldbackground=p["panel_alt"],
                    background=p["panel_alt"], foreground=p["fg"],
                    arrowcolor=p["accent"], borderwidth=1,
                    selectbackground=p["panel_alt"], selectforeground=p["fg"])
    root.option_add("*TCombobox*Listbox.background", p["panel_alt"])
    root.option_add("*TCombobox*Listbox.foreground", p["fg"])
    root.option_add("*TCombobox*Listbox.selectBackground", p["accent"])
    root.option_add("*TCombobox*Listbox.selectForeground", p["banner_fg"])

    # Entry
    style.configure("TEntry", fieldbackground=p["panel_alt"],
                    foreground=p["fg"], insertcolor=p["accent"],
                    borderwidth=1, bordercolor=p["border"])

    # Scrollbar
    style.configure("Vertical.TScrollbar", background=p["panel_alt"],
                    troughcolor=p["bg"], borderwidth=0, arrowcolor=p["fg_dim"])
    style.configure("Horizontal.TScrollbar", background=p["panel_alt"],
                    troughcolor=p["bg"], borderwidth=0, arrowcolor=p["fg_dim"])

    # PanedWindow
    style.configure("TPanedwindow", background=p["bg"])


def main():
    # 啟動時先偵測本機硬體，蓋掉 HARDWARE[AGENT] 那列
    local_hw = detect_local_hardware()
    if local_hw:
        HARDWARE[AGENT] = local_hw

    root = tk.Tk()
    apply_pleiadex_theme(root)
    app = DeltaDashboard(root)
    root.mainloop()


if __name__ == "__main__":
    main()
