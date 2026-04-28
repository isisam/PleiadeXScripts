#!/usr/bin/env python3
"""
PleiadeX MQTT Chat Client (v0.1, 2026-04-27)

每個 Agent (Alpha/Beta/Gamma/Delta/Epsilon/Zeta/Shion/...) 跑這一支當常駐 chat 服務。
跑在 tmux session 裡，主人/agent attach 進去就是「session 視窗」：
  - 上半部：接收訊息 stream（自動加時間戳 + 簽名）
  - 下半部：輸入欄位（直接打字 enter 發送，或加 prefix 控制收信對象）

預設指令：
  /broadcast <text>      → 全體廣播
  /to <agent> <text>     → 直送某 agent inbox
  /sub <topic>           → 訂閱額外 topic
  /unsub <topic>         → 取消訂閱
  /status                → 看自己訂閱清單與連線狀態
  /quit                  → 離線（先 publish offline status）
  其他文字（無 / 開頭）   → 預設行為：廣播（可改 config default_target）

Topics:
  pleiadex/agents/{me}/inbox       自己收信（私訊）
  pleiadex/broadcast               全體廣播
  pleiadex/agents/{me}/status      自己心跳（retained）
  pleiadex/memory/synced           記憶同步通知
  pleiadex/system/+                系統事件

訊息格式（JSON）：
  {
    "from": "Alpha",
    "to": "broadcast" | "<agent>",
    "text": "...",
    "ts": "2026-04-27T23:45:01+0800",
    "msg_id": "<uuid>"
  }

Usage:
  python3 pleiadex_mqtt_chat.py --agent Alpha
  python3 pleiadex_mqtt_chat.py --agent Delta --broker 192.168.1.200
  python3 pleiadex_mqtt_chat.py --config configs/Delta.yaml

Config (yaml)：
  agent: Delta
  broker: 192.168.1.200
  port: 1883
  default_target: broadcast    # 或 "Alpha" 把無前綴訊息預設送 Alpha
  extra_subscribe:
    - pleiadex/walsin/+
"""

import argparse
import atexit
import json
import os
import queue
import signal
import subprocess
import sys
import tempfile
import threading
import time
import uuid
from datetime import datetime
from pathlib import Path

try:
    import fcntl
except ImportError:
    fcntl = None

try:
    import msvcrt
except ImportError:
    msvcrt = None

try:
    import paho.mqtt.client as mqtt
except ImportError:
    print("ERROR: paho-mqtt 未安裝。執行：pip3 install --user --break-system-packages paho-mqtt", file=sys.stderr)
    sys.exit(1)

try:
    import yaml
    HAS_YAML = True
except ImportError:
    HAS_YAML = False


def now_iso():
    return datetime.now().astimezone().strftime('%Y-%m-%dT%H:%M:%S%z')


def now_short():
    return datetime.now().strftime('%H:%M:%S')


_LOCK_HANDLE = None


def _lock_path_for_agent(agent):
    return Path(tempfile.gettempdir()) / f'pleiadex-{agent}.lock'


def _try_lock_file(fh):
    if os.name == 'nt':
        if msvcrt is None:
            raise RuntimeError('msvcrt unavailable on Windows')
        try:
            fh.seek(0)
            msvcrt.locking(fh.fileno(), msvcrt.LK_NBLCK, 1)
            return True
        except OSError:
            return False
    if fcntl is None:
        raise RuntimeError('fcntl unavailable on non-Windows platform')
    try:
        fcntl.flock(fh.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
        return True
    except BlockingIOError:
        return False


def _unlock_file(fh):
    if os.name == 'nt':
        if msvcrt is not None:
            fh.seek(0)
            msvcrt.locking(fh.fileno(), msvcrt.LK_UNLCK, 1)
    elif fcntl is not None:
        fcntl.flock(fh.fileno(), fcntl.LOCK_UN)


def acquire_singleton_lock(agent):
    """確保同一 agent 全機唯一 client。已有實例時 exit 0。"""
    global _LOCK_HANDLE
    lock_path = _lock_path_for_agent(agent)
    lock_path.parent.mkdir(parents=True, exist_ok=True)
    # 'a+' 不 truncate，rejected 時還能讀到原 holder 的 PID
    fh = open(lock_path, 'a+')
    try:
        acquired = _try_lock_file(fh)
    except Exception as e:
        fh.close()
        print(f'[lock] cannot acquire {lock_path}: {e}', file=sys.stderr, flush=True)
        sys.exit(1)

    if not acquired:
        try:
            fh.seek(0)
            pid = fh.read().strip() or '?'
        except Exception:
            pid = '?'
        fh.close()
        print(f'[lock] another {agent} instance running (pid={pid}), exit.', flush=True)
        sys.exit(0)

    # 拿到鎖才 truncate 寫自己的 PID
    fh.seek(0)
    fh.truncate(0)
    fh.write(str(os.getpid()))
    fh.flush()
    _LOCK_HANDLE = fh

    def _release():
        global _LOCK_HANDLE
        handle = _LOCK_HANDLE
        _LOCK_HANDLE = None
        if handle is None:
            return
        try:
            _unlock_file(handle)
        except Exception:
            pass
        try:
            handle.close()
        except Exception:
            pass
        try:
            lock_path.unlink(missing_ok=True)
        except Exception:
            pass

    atexit.register(_release)


APPLE_MODEL_NAMES = {
    "Macmini9,1":      "M1 Mac mini",
    "Mac14,3":         "M2 Mac mini",
    "Mac14,12":        "M2 Pro Mac mini",
    "Mac16,10":        "M4 Mac mini",
    "Mac16,11":        "M4 Pro Mac mini",
    "MacBookAir10,1":  "M1 MacBook Air",
    "Mac14,2":         "M2 MacBook Air",
    "Mac15,12":        "M3 MacBook Air",
    "Mac16,12":        "M4 MacBook Air 13",
    "Mac16,13":        "M4 MacBook Air 15",
    "MacBookPro17,1":  "M1 MacBook Pro 13",
    "MacBookPro18,1":  "M1 Pro MacBook Pro 16",
    "MacBookPro18,2":  "M1 Max MacBook Pro 16",
    "MacBookPro18,3":  "M1 Pro MacBook Pro 14",
    "MacBookPro18,4":  "M1 Max MacBook Pro 14",
    "Mac14,5":         "M2 Max MacBook Pro 14",
    "Mac14,6":         "M2 Max MacBook Pro 16",
    "Mac15,3":         "M3 MacBook Pro 14",
    "Mac15,7":         "M3 Max MacBook Pro 14",
    "Mac15,8":         "M3 Pro MacBook Pro 16",
    "Mac16,1":         "M4 MacBook Pro 14",
    "Mac16,5":         "M4 Pro MacBook Pro 14",
    "Mac16,6":         "M4 Max MacBook Pro 16",
    "iMac21,1":        "M1 iMac",
    "Mac15,4":         "M3 iMac",
    "Mac16,2":         "M4 iMac",
}


def detect_local_hardware():
    """跨平台抓本機型號 / RAM / 磁碟。失敗回 None；其他 dashboard 看到時就會 retain 顯示真值。"""
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
        elif sys.platform == "win32":
            import ctypes, shutil
            class MEMORYSTATUSEX(ctypes.Structure):
                _fields_ = [("dwLength", ctypes.c_ulong),
                            ("dwMemoryLoad", ctypes.c_ulong),
                            ("ullTotalPhys", ctypes.c_ulonglong),
                            ("ullAvailPhys", ctypes.c_ulonglong),
                            ("ullTotalPageFile", ctypes.c_ulonglong),
                            ("ullAvailPageFile", ctypes.c_ulonglong),
                            ("ullTotalVirtual", ctypes.c_ulonglong),
                            ("ullAvailVirtual", ctypes.c_ulonglong),
                            ("ullExtendedVirtual", ctypes.c_ulonglong)]
            ms = MEMORYSTATUSEX()
            ms.dwLength = ctypes.sizeof(ms)
            ctypes.windll.kernel32.GlobalMemoryStatusEx(ctypes.byref(ms))
            ram_gb = ms.ullTotalPhys // (1024 ** 3)
            disk_gb = shutil.disk_usage("C:\\").total // (1024 ** 3)
            cpu = "Unknown CPU"
            try:
                out = subprocess.check_output(["wmic", "cpu", "get", "name"],
                                              text=True, timeout=3)
                names = [l.strip() for l in out.splitlines() if l.strip() and l.strip().lower() != "name"]
                if names:
                    cpu = names[0]
            except Exception:
                pass
            return f"{cpu} · {ram_gb}G / {disk_gb}G · Win"
        elif sys.platform == "linux":
            import shutil
            try:
                with open("/proc/meminfo") as f:
                    mem = f.read()
                ram_kb = int(next(l for l in mem.splitlines() if l.startswith("MemTotal:")).split()[1])
                ram_gb = ram_kb // (1024 ** 2)
            except Exception:
                ram_gb = 0
            try:
                disk_gb = shutil.disk_usage("/").total // (1024 ** 3)
            except Exception:
                disk_gb = 0
            cpu = "Unknown CPU"
            try:
                with open("/proc/cpuinfo") as f:
                    for line in f:
                        if line.startswith("model name"):
                            cpu = line.split(":", 1)[1].strip()
                            break
            except Exception:
                pass
            return f"{cpu} · {ram_gb}G / {disk_gb}G · Linux"
    except Exception:
        return None
    return None


def wait_forever():
    if hasattr(signal, 'pause'):
        while True:
            signal.pause()
    while True:
        time.sleep(3600)


def safe_print(*args, **kwargs):
    try:
        print(*args, **kwargs)
    except UnicodeEncodeError:
        sep = kwargs.get('sep', ' ')
        end = kwargs.get('end', '\n')
        file = kwargs.get('file', sys.stdout)
        flush = kwargs.get('flush', False)
        text = sep.join(str(arg) for arg in args)
        safe_text = text.encode(file.encoding or 'utf-8', errors='backslashreplace').decode(file.encoding or 'utf-8', errors='strict')
        file.write(safe_text + end)
        if flush:
            file.flush()


class PleiadexClient:
    def __init__(self, agent, broker, port=1883, default_target='broadcast', extra_subscribe=None, log_dir=None):
        self.agent = agent
        self.broker = broker
        self.port = port
        self.default_target = default_target
        self.extra_subscribe = extra_subscribe or []
        self.log_dir = Path(log_dir) if log_dir else Path.home() / '.pleiadex' / 'mqtt_logs'
        self.log_dir.mkdir(parents=True, exist_ok=True)
        self.log_file = self.log_dir / f'{agent}_{datetime.now():%Y-%m-%d}.log'

        self.subscriptions = set()
        self.connected = False
        self.client = mqtt.Client(client_id=f'pleiadex-{agent}-{os.getpid()}', clean_session=True)
        self.client.on_connect = self._on_connect
        self.client.on_message = self._on_message
        self.client.on_disconnect = self._on_disconnect

        self.client.will_set(
            f'pleiadex/agents/{agent}/status',
            payload=json.dumps({"agent": agent, "status": "offline_lwt", "ts": now_iso()}),
            qos=1, retain=True
        )

    def _on_connect(self, client, userdata, flags, rc):
        if rc == 0:
            self.connected = True
            self._print_sys(f'connected to {self.broker}:{self.port}')

            base_topics = [
                f'pleiadex/agents/{self.agent}/inbox',
                'pleiadex/broadcast',
                'pleiadex/memory/synced',
                'pleiadex/system/+',
            ]
            for t in base_topics + list(self.extra_subscribe):
                client.subscribe(t, qos=1)
                self.subscriptions.add(t)

            self.publish_status('online')
            self.publish_hardware()
        else:
            self._print_sys(f'connect failed rc={rc}')

    def _on_disconnect(self, client, userdata, rc):
        self.connected = False
        self._print_sys(f'disconnected rc={rc}')

    def _on_message(self, client, userdata, msg):
        try:
            payload = msg.payload.decode('utf-8')
        except Exception:
            payload = repr(msg.payload)

        try:
            data = json.loads(payload)
            sender = data.get('from', '?')
            text = data.get('text', payload)
            ts = data.get('ts', now_iso())
        except json.JSONDecodeError:
            sender = '?'
            text = payload
            ts = now_iso()

        line = f'[{now_short()}] [{msg.topic}] {sender}: {text}'
        try:
            with open(self.log_file, 'a', encoding='utf-8') as f:
                f.write(f'{ts} {line}\n')
        except Exception:
            pass
        safe_print(line, flush=True)

    def _print_sys(self, msg):
        safe_print(f'[{now_short()}] [system] {msg}', flush=True)

    def publish_status(self, status):
        topic = f'pleiadex/agents/{self.agent}/status'
        payload = json.dumps({"agent": self.agent, "status": status, "ts": now_iso(), "pid": os.getpid()})
        self.client.publish(topic, payload, qos=1, retain=True)

    def publish_hardware(self):
        """retained：把本機 sysctl/wmic/proc 偵測到的硬體資訊發到 MQTT，給 dashboard 看真實值。"""
        hw = detect_local_hardware() or "未偵測到"
        topic = f'pleiadex/agents/{self.agent}/hardware'
        payload = json.dumps({
            "agent": self.agent,
            "hardware": hw,
            "ts": now_iso(),
            "platform": sys.platform,
        }, ensure_ascii=False)
        self.client.publish(topic, payload, qos=1, retain=True)
        self._print_sys(f'hardware retained: {hw}')

    def publish_message(self, target, text):
        msg_id = str(uuid.uuid4())
        payload = json.dumps({
            "from": self.agent,
            "to": target,
            "text": text,
            "ts": now_iso(),
            "msg_id": msg_id,
        })
        if target == 'broadcast':
            topic = 'pleiadex/broadcast'
        else:
            topic = f'pleiadex/agents/{target}/inbox'
        self.client.publish(topic, payload, qos=1)
        return topic, msg_id

    def heartbeat_loop(self, interval=30):
        while True:
            time.sleep(interval)
            if self.connected:
                self.publish_status('online')

    def start(self):
        self.client.connect(self.broker, self.port, keepalive=60)
        self.client.loop_start()
        threading.Thread(target=self.heartbeat_loop, daemon=True).start()

    def stop(self):
        try:
            self.publish_status('offline')
            time.sleep(0.5)
        finally:
            self.client.loop_stop()
            self.client.disconnect()


def input_loop(client_obj):
    print(f'[{now_short()}] [system] {client_obj.agent} ready. Type message + Enter; /help for commands.', flush=True)
    while True:
        try:
            line = input(f'{client_obj.agent}> ').strip()
        except (EOFError, KeyboardInterrupt):
            print()
            client_obj.stop()
            return
        if not line:
            continue
        try:
            handle_command(client_obj, line)
        except SystemExit:
            return
        except Exception as e:
            safe_print(f'[error] {e}', flush=True)


def handle_command(client_obj, line):
    if line.startswith('/'):
        parts = line.split(None, 2)
        cmd = parts[0].lower()
        if cmd == '/help':
            print(__doc__.split('Topics:')[0])
        elif cmd == '/broadcast':
            text = line[len('/broadcast'):].strip()
            if not text:
                print('usage: /broadcast <text>')
                return
            t, mid = client_obj.publish_message('broadcast', text)
            print(f'  → {t} (msg_id={mid[:8]})')
        elif cmd == '/to':
            if len(parts) < 3:
                print('usage: /to <agent> <text>')
                return
            target = parts[1]
            text = parts[2]
            t, mid = client_obj.publish_message(target, text)
            print(f'  → {t} (msg_id={mid[:8]})')
        elif cmd == '/sub':
            if len(parts) < 2:
                print('usage: /sub <topic>')
                return
            topic = parts[1]
            client_obj.client.subscribe(topic, qos=1)
            client_obj.subscriptions.add(topic)
            print(f'  subscribed: {topic}')
        elif cmd == '/unsub':
            if len(parts) < 2:
                print('usage: /unsub <topic>')
                return
            topic = parts[1]
            client_obj.client.unsubscribe(topic)
            client_obj.subscriptions.discard(topic)
            print(f'  unsubscribed: {topic}')
        elif cmd == '/status':
            print(f'  agent: {client_obj.agent}')
            print(f'  broker: {client_obj.broker}:{client_obj.port}')
            print(f'  connected: {client_obj.connected}')
            print(f'  subscriptions:')
            for s in sorted(client_obj.subscriptions):
                print(f'    - {s}')
            print(f'  log: {client_obj.log_file}')
        elif cmd in ('/quit', '/exit'):
            client_obj.stop()
            sys.exit(0)
        else:
            print(f'unknown command: {cmd}. /help for list.')
    else:
        target = client_obj.default_target
        t, mid = client_obj.publish_message(target, line)
        print(f'  → {t} (msg_id={mid[:8]})')


def load_config(path):
    if not HAS_YAML:
        print('ERROR: yaml 未安裝，無法讀 config 檔。pip3 install --user --break-system-packages pyyaml', file=sys.stderr)
        sys.exit(1)
    with open(path, encoding='utf-8') as f:
        return yaml.safe_load(f)


def main():
    parser = argparse.ArgumentParser(description='PleiadeX MQTT Chat Client')
    parser.add_argument('--agent', help='Agent name (e.g. Alpha, Delta, Zeta)')
    parser.add_argument('--broker', default='192.168.1.200', help='MQTT broker host')
    parser.add_argument('--port', type=int, default=1883, help='MQTT broker port')
    parser.add_argument('--default-target', default='broadcast',
                        help='Default destination for un-prefixed messages')
    parser.add_argument('--config', help='YAML config file (overrides CLI flags)')
    args = parser.parse_args()

    cfg = {
        'agent': args.agent,
        'broker': args.broker,
        'port': args.port,
        'default_target': args.default_target,
        'extra_subscribe': [],
    }
    if args.config:
        cfg.update(load_config(args.config))

    if not cfg.get('agent'):
        parser.error('--agent or config.agent is required')

    acquire_singleton_lock(cfg['agent'])

    client_obj = PleiadexClient(
        agent=cfg['agent'],
        broker=cfg['broker'],
        port=cfg['port'],
        default_target=cfg.get('default_target', 'broadcast'),
        extra_subscribe=cfg.get('extra_subscribe', []),
    )

    def sig_handler(signum, frame):
        safe_print('\n[signal] shutting down...', flush=True)
        client_obj.stop()
        sys.exit(0)

    signal.signal(signal.SIGINT, sig_handler)
    signal.signal(signal.SIGTERM, sig_handler)

    client_obj.start()
    time.sleep(0.5)

    # daemon mode：stdin 不是 tty 時不進 input loop（背景啟動沒人打字）
    # Why: helper 用 nohup ... </dev/null & 起 process 時 input() 會 EOF
    # 立刻退出觸發 atexit 清 lock，client 連上 broker 一秒就斷
    if sys.stdin.isatty():
        input_loop(client_obj)
    else:
        safe_print(f'[{now_short()}] [system] {cfg["agent"]} daemon mode (stdin not tty)', flush=True)
        try:
            wait_forever()
        except (KeyboardInterrupt, SystemExit):
            pass
        finally:
            client_obj.stop()


if __name__ == '__main__':
    main()
