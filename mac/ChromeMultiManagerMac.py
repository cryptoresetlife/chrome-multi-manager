#!/usr/bin/env python3
import base64
import hashlib
import json
import math
import os
import re
import secrets
import select
import shutil
import socket
import struct
import subprocess
import sys
import threading
import time
import urllib.parse
import urllib.request
from pathlib import Path
from tkinter import filedialog, messagebox, simpledialog, ttk
import tkinter as tk


APP_TITLE = "Chrome 多开管理器 macOS"
APP_VERSION = "1.0.0-mac.1"
CONFIG_DIR = Path.home() / "Library" / "Application Support" / "ChromeMultiManager"
PROFILE_DIR = CONFIG_DIR / "Profiles"
CONFIG_FILE = CONFIG_DIR / "config.json"

CHROME_PATHS = [
    "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
    str(Path.home() / "Applications" / "Google Chrome.app" / "Contents" / "MacOS" / "Google Chrome"),
    "/Applications/Google Chrome Beta.app/Contents/MacOS/Google Chrome Beta",
    "/Applications/Google Chrome Canary.app/Contents/MacOS/Google Chrome Canary",
]


def ensure_dirs():
    CONFIG_DIR.mkdir(parents=True, exist_ok=True)
    PROFILE_DIR.mkdir(parents=True, exist_ok=True)


def find_chrome():
    for path in CHROME_PATHS:
        if Path(path).exists():
            return path
    found = shutil.which("google-chrome") or shutil.which("chrome")
    return found or ""


def next_debug_port(profile_id):
    return 19000 + int(profile_id)


def profile_store_dir(profile):
    return PROFILE_DIR / ("profile_%03d" % int(profile["id"]))


def port_open(port, timeout=0.18):
    try:
        with socket.create_connection(("127.0.0.1", int(port)), timeout=timeout):
            return True
    except OSError:
        return False


def ps_lines():
    if sys.platform != "darwin":
        return []
    try:
        out = subprocess.check_output(["/bin/ps", "-axo", "pid=,command="], text=True, stderr=subprocess.DEVNULL)
        return out.splitlines()
    except Exception:
        return []


def pid_for_debug_port(port):
    needle = "--remote-debugging-port=%s" % int(port)
    for line in ps_lines():
        if needle in line:
            parts = line.strip().split(None, 1)
            if parts and parts[0].isdigit():
                return int(parts[0])
    return None


def normalize_proxy(proxy):
    proxy = (proxy or "").strip()
    if not proxy:
        return ""
    if "://" in proxy:
        return proxy
    return "http://" + proxy


def parse_auth_proxy(proxy):
    proxy = normalize_proxy(proxy)
    if not proxy:
        return None
    try:
        parsed = urllib.parse.urlsplit(proxy)
        if parsed.username and parsed.password and parsed.hostname and parsed.port:
            return {
                "scheme": parsed.scheme or "http",
                "host": parsed.hostname,
                "port": int(parsed.port),
                "user": urllib.parse.unquote(parsed.username),
                "password": urllib.parse.unquote(parsed.password),
            }
    except Exception:
        return None
    return None


def proxy_host(proxy):
    proxy = normalize_proxy(proxy)
    if not proxy:
        return ""
    try:
        parsed = urllib.parse.urlsplit(proxy)
        return parsed.hostname or ""
    except Exception:
        return ""


def read_http_json(url, timeout=2):
    req = urllib.request.Request(url, headers={"User-Agent": "ChromeMultiManagerMac/%s" % APP_VERSION})
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return json.loads(resp.read().decode("utf-8", "replace"))


def recv_exact(sock, size):
    data = b""
    while len(data) < size:
        chunk = sock.recv(size - len(data))
        if not chunk:
            raise ConnectionError("socket closed")
        data += chunk
    return data


def send_ws_text(sock, text):
    payload = text.encode("utf-8")
    mask = secrets.token_bytes(4)
    header = bytearray([0x81])
    length = len(payload)
    if length < 126:
        header.append(0x80 | length)
    elif length < 65536:
        header.append(0x80 | 126)
        header.extend(struct.pack("!H", length))
    else:
        header.append(0x80 | 127)
        header.extend(struct.pack("!Q", length))
    masked = bytes(b ^ mask[i % 4] for i, b in enumerate(payload))
    sock.sendall(bytes(header) + mask + masked)


def recv_ws_text(sock):
    while True:
        first, second = recv_exact(sock, 2)
        opcode = first & 0x0F
        masked = bool(second & 0x80)
        length = second & 0x7F
        if length == 126:
            length = struct.unpack("!H", recv_exact(sock, 2))[0]
        elif length == 127:
            length = struct.unpack("!Q", recv_exact(sock, 8))[0]
        mask = recv_exact(sock, 4) if masked else b""
        payload = recv_exact(sock, length) if length else b""
        if masked:
            payload = bytes(b ^ mask[i % 4] for i, b in enumerate(payload))
        if opcode == 0x8:
            return ""
        if opcode == 0x9:
            continue
        if opcode in (0x1, 0x2):
            return payload.decode("utf-8", "replace")


def websocket_send(ws_url, payload, timeout=4):
    parsed = urllib.parse.urlsplit(ws_url)
    host = parsed.hostname or "127.0.0.1"
    port = parsed.port or 80
    path = parsed.path or "/"
    if parsed.query:
        path += "?" + parsed.query
    key = base64.b64encode(secrets.token_bytes(16)).decode("ascii")
    with socket.create_connection((host, port), timeout=timeout) as sock:
        sock.settimeout(timeout)
        handshake = (
            "GET %s HTTP/1.1\r\n"
            "Host: %s:%s\r\n"
            "Upgrade: websocket\r\n"
            "Connection: Upgrade\r\n"
            "Sec-WebSocket-Key: %s\r\n"
            "Sec-WebSocket-Version: 13\r\n\r\n"
        ) % (path, host, port, key)
        sock.sendall(handshake.encode("ascii"))
        raw = b""
        while b"\r\n\r\n" not in raw:
            raw += sock.recv(4096)
            if len(raw) > 65536:
                raise ConnectionError("websocket handshake too large")
        if b" 101 " not in raw.split(b"\r\n", 1)[0]:
            raise ConnectionError("websocket upgrade failed")
        send_ws_text(sock, json.dumps(payload, ensure_ascii=False, separators=(",", ":")))
        return recv_ws_text(sock)


def cdp_page(port):
    try:
        pages = read_http_json("http://127.0.0.1:%s/json" % int(port), timeout=2)
        for page in pages:
            if page.get("type") == "page" and page.get("webSocketDebuggerUrl"):
                return page
    except Exception:
        return None
    return None


def cdp_send(port, method, params=None):
    page = cdp_page(port)
    if not page:
        return False
    payload = {"id": int(time.time() * 1000) % 1000000, "method": method, "params": params or {}}
    try:
        websocket_send(page["webSocketDebuggerUrl"], payload)
        return True
    except Exception:
        return False


def cdp_nav(port, url):
    return cdp_send(port, "Page.navigate", {"url": url})


def cdp_eval(port, expression):
    return cdp_send(port, "Runtime.evaluate", {"expression": expression})


class LocalAuthProxy:
    def __init__(self, local_port, upstream):
        self.local_port = int(local_port)
        self.upstream = upstream
        self.stop_event = threading.Event()
        self.server = None
        self.thread = None

    def start(self):
        if self.thread and self.thread.is_alive():
            return
        self.thread = threading.Thread(target=self._run, name="LocalAuthProxy-%s" % self.local_port, daemon=True)
        self.thread.start()
        time.sleep(0.08)

    def stop(self):
        self.stop_event.set()
        try:
            if self.server:
                self.server.close()
        except Exception:
            pass

    def _run(self):
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as server:
            self.server = server
            server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            server.bind(("127.0.0.1", self.local_port))
            server.listen(64)
            server.settimeout(0.3)
            while not self.stop_event.is_set():
                try:
                    client, _ = server.accept()
                except socket.timeout:
                    continue
                except OSError:
                    break
                threading.Thread(target=self._handle, args=(client,), daemon=True).start()

    def _read_header(self, sock):
        data = b""
        while b"\r\n\r\n" not in data and len(data) < 65536:
            chunk = sock.recv(4096)
            if not chunk:
                break
            data += chunk
        return data

    def _with_auth(self, header):
        text = header.decode("iso-8859-1", "replace")
        lines = text.split("\r\n")
        token = base64.b64encode(("%s:%s" % (self.upstream["user"], self.upstream["password"])).encode("utf-8")).decode("ascii")
        if not any(line.lower().startswith("proxy-authorization:") for line in lines):
            lines.insert(1, "Proxy-Authorization: Basic " + token)
        if not any(line.lower().startswith("proxy-connection:") for line in lines):
            lines.insert(1, "Proxy-Connection: Keep-Alive")
        return "\r\n".join(lines).encode("iso-8859-1", "replace")

    def _pipe(self, left, right):
        sockets = [left, right]
        try:
            while sockets and not self.stop_event.is_set():
                readable, _, _ = select.select(sockets, [], [], 0.5)
                for sock in readable:
                    other = right if sock is left else left
                    data = sock.recv(8192)
                    if not data:
                        return
                    other.sendall(data)
        except Exception:
            return

    def _handle(self, client):
        with client:
            try:
                client.settimeout(8)
                raw = self._read_header(client)
                if not raw:
                    return
                header, rest = raw.split(b"\r\n\r\n", 1)
                upstream = socket.create_connection((self.upstream["host"], self.upstream["port"]), timeout=8)
                with upstream:
                    upstream.sendall(self._with_auth(header + b"\r\n\r\n") + rest)
                    self._pipe(client, upstream)
            except Exception:
                return


class ProfileDialog(simpledialog.Dialog):
    def __init__(self, parent, title, profile=None):
        self.profile = profile or {}
        self.result = None
        super().__init__(parent, title)

    def body(self, master):
        self.entries = {}
        rows = [
            ("name", "名称", self.profile.get("name", "")),
            ("group", "分组", self.profile.get("group", "默认")),
            ("proxy", "代理", self.profile.get("proxy", "")),
            ("note", "备注", self.profile.get("note", "")),
        ]
        for row, (key, label, value) in enumerate(rows):
            tk.Label(master, text=label).grid(row=row, column=0, sticky="w", padx=(0, 8), pady=5)
            entry = tk.Entry(master, width=46)
            entry.insert(0, value)
            entry.grid(row=row, column=1, sticky="ew", pady=5)
            self.entries[key] = entry
        tk.Label(master, text="代理格式: http://用户名:密码@IP:端口 或 IP:端口").grid(
            row=len(rows), column=0, columnspan=2, sticky="w", pady=(4, 0)
        )
        return self.entries["name"]

    def apply(self):
        name = self.entries["name"].get().strip()
        if not name:
            name = "账号"
        self.result = {
            "name": name,
            "group": self.entries["group"].get().strip() or "默认",
            "proxy": self.entries["proxy"].get().strip(),
            "note": self.entries["note"].get().strip(),
        }


class ChromeManagerApp:
    def __init__(self):
        ensure_dirs()
        self.chrome = find_chrome()
        self.profiles = []
        self.local_proxies = {}
        self.last_badge_at = 0.0
        self.root = tk.Tk()
        self.root.title("%s %s" % (APP_TITLE, APP_VERSION))
        self.root.geometry("1080x700")
        self.root.minsize(900, 560)
        self.load_config()
        self.build_ui()
        self.refresh_ui()
        self.root.after(5000, self.tick)
        self.root.protocol("WM_DELETE_WINDOW", self.on_close)

    def load_config(self):
        self.profiles = []
        if not CONFIG_FILE.exists():
            return
        try:
            data = json.loads(CONFIG_FILE.read_text(encoding="utf-8"))
            if isinstance(data, dict):
                data = [data]
            for item in data:
                profile_id = int(item.get("id") or len(self.profiles) + 1)
                self.profiles.append({
                    "id": profile_id,
                    "name": str(item.get("name") or "账号%s" % profile_id),
                    "group": str(item.get("group") or "默认"),
                    "proxy": str(item.get("proxy") or ""),
                    "note": str(item.get("note") or ""),
                    "pid": item.get("pid"),
                    "debugPort": int(item.get("debugPort") or next_debug_port(profile_id)),
                })
        except Exception as exc:
            messagebox.showerror("配置读取失败", str(exc))

    def save_config(self):
        data = []
        for profile in self.profiles:
            data.append({
                "id": int(profile["id"]),
                "name": profile.get("name", ""),
                "group": profile.get("group", ""),
                "proxy": profile.get("proxy", ""),
                "note": profile.get("note", ""),
                "pid": profile.get("pid"),
                "debugPort": int(profile.get("debugPort") or next_debug_port(profile["id"])),
            })
        CONFIG_FILE.write_text(json.dumps(data, ensure_ascii=False, indent=2), encoding="utf-8")

    def next_id(self):
        return max([int(p["id"]) for p in self.profiles] or [0]) + 1

    def profile_by_id(self, profile_id):
        for profile in self.profiles:
            if int(profile["id"]) == int(profile_id):
                return profile
        return None

    def build_ui(self):
        style = ttk.Style()
        try:
            style.theme_use("clam")
        except Exception:
            pass

        root = ttk.Frame(self.root, padding=12)
        root.pack(fill="both", expand=True)
        root.columnconfigure(1, weight=1)
        root.rowconfigure(0, weight=1)

        sidebar = ttk.Frame(root)
        sidebar.grid(row=0, column=0, sticky="ns", padx=(0, 12))

        buttons = [
            ("新建配置", self.new_profile),
            ("编辑选中", self.edit_profile),
            ("删除选中", self.delete_profile),
            ("启动选中", self.launch_selected),
            ("全部启动", self.launch_all),
            ("关闭选中", self.stop_selected),
            ("全部关闭", self.stop_all),
            ("排列窗口", self.arrange_windows),
            ("导入代理", self.import_proxies),
            ("刷新状态", lambda: self.refresh_ui(force_badges=True)),
        ]
        for text, command in buttons:
            ttk.Button(sidebar, text=text, command=command).pack(fill="x", pady=4)

        main = ttk.Frame(root)
        main.grid(row=0, column=1, sticky="nsew")
        main.rowconfigure(0, weight=1)
        main.columnconfigure(0, weight=1)

        columns = ("id", "name", "group", "proxy", "status", "note")
        self.tree = ttk.Treeview(main, columns=columns, show="headings", selectmode="extended")
        headings = {
            "id": "#",
            "name": "名称",
            "group": "分组",
            "proxy": "代理",
            "status": "状态",
            "note": "备注",
        }
        widths = {"id": 50, "name": 130, "group": 90, "proxy": 360, "status": 90, "note": 150}
        for column in columns:
            self.tree.heading(column, text=headings[column])
            self.tree.column(column, width=widths[column], minwidth=40, stretch=(column in ("proxy", "note")))
        scrollbar = ttk.Scrollbar(main, orient="vertical", command=self.tree.yview)
        self.tree.configure(yscrollcommand=scrollbar.set)
        self.tree.grid(row=0, column=0, sticky="nsew")
        scrollbar.grid(row=0, column=1, sticky="ns")
        self.tree.bind("<Double-1>", lambda _event: self.toggle_selected())

        controls = ttk.LabelFrame(root, text="群控", padding=10)
        controls.grid(row=1, column=0, columnspan=2, sticky="ew", pady=(12, 0))
        controls.columnconfigure(1, weight=1)
        ttk.Label(controls, text="URL").grid(row=0, column=0, sticky="w")
        self.url_var = tk.StringVar(value="https://www.google.com")
        ttk.Entry(controls, textvariable=self.url_var).grid(row=0, column=1, sticky="ew", padx=8)
        self.only_selected = tk.BooleanVar(value=False)
        ttk.Checkbutton(controls, text="仅选中", variable=self.only_selected).grid(row=0, column=2, padx=8)
        ttk.Button(controls, text="全部跳转", command=self.group_goto).grid(row=0, column=3)

        ttk.Label(controls, text="JS").grid(row=1, column=0, sticky="nw", pady=(8, 0))
        self.js_text = tk.Text(controls, height=3, width=60)
        self.js_text.grid(row=1, column=1, sticky="ew", padx=8, pady=(8, 0))
        ttk.Button(controls, text="执行 JS", command=self.group_exec).grid(row=1, column=3, sticky="n", pady=(8, 0))

        self.status_var = tk.StringVar(value="")
        ttk.Label(root, textvariable=self.status_var).grid(row=2, column=0, columnspan=2, sticky="ew", pady=(8, 0))

    def selected_profiles(self):
        result = []
        for item in self.tree.selection():
            values = self.tree.item(item, "values")
            if values:
                profile = self.profile_by_id(values[0])
                if profile:
                    result.append(profile)
        return result

    def target_profiles(self):
        return self.selected_profiles() if self.only_selected.get() else list(self.profiles)

    def is_running(self, profile):
        if port_open(profile["debugPort"]):
            pid = pid_for_debug_port(profile["debugPort"])
            if pid:
                profile["pid"] = pid
            return True
        profile["pid"] = None
        return False

    def set_status(self, text):
        self.status_var.set(text)
        self.root.update_idletasks()

    def refresh_ui(self, force_badges=False):
        selected_ids = set()
        for item in self.tree.selection():
            values = self.tree.item(item, "values")
            if values:
                selected_ids.add(str(values[0]))
        for item in self.tree.get_children():
            self.tree.delete(item)
        running_count = 0
        for profile in self.profiles:
            running = self.is_running(profile)
            if running:
                running_count += 1
            values = (
                profile["id"],
                profile["name"],
                profile["group"],
                profile["proxy"],
                "运行中" if running else "已停止",
                profile["note"],
            )
            iid = str(profile["id"])
            self.tree.insert("", "end", iid=iid, values=values)
            if iid in selected_ids:
                self.tree.selection_add(iid)
        total = len(self.profiles)
        self.set_status("配置: %s   运行中: %s   已停止: %s   存档: %s" % (
            total, running_count, total - running_count, PROFILE_DIR
        ))
        if force_badges:
            self.refresh_badges(force=True)

    def new_profile(self):
        dialog = ProfileDialog(self.root, "新建配置")
        if not dialog.result:
            return
        profile_id = self.next_id()
        profile = {
            "id": profile_id,
            "name": dialog.result["name"],
            "group": dialog.result["group"],
            "proxy": dialog.result["proxy"],
            "note": dialog.result["note"],
            "pid": None,
            "debugPort": next_debug_port(profile_id),
        }
        self.profiles.append(profile)
        self.save_config()
        self.refresh_ui()

    def edit_profile(self):
        selected = self.selected_profiles()
        if len(selected) != 1:
            messagebox.showinfo("提示", "请选中一个配置。")
            return
        profile = selected[0]
        dialog = ProfileDialog(self.root, "编辑配置", profile)
        if not dialog.result:
            return
        profile.update(dialog.result)
        self.save_config()
        self.refresh_ui(force_badges=True)

    def delete_profile(self):
        selected = self.selected_profiles()
        if not selected:
            return
        if not messagebox.askyesno("确认", "确认删除 %s 个配置？存档文件夹不会自动删除。" % len(selected)):
            return
        for profile in selected:
            self.stop_profile(profile)
            self.profiles.remove(profile)
        self.save_config()
        self.refresh_ui()

    def import_proxies(self):
        file_name = filedialog.askopenfilename(
            title="选择代理文件",
            filetypes=[("Text files", "*.txt"), ("All files", "*.*")]
        )
        if not file_name:
            return
        count = 0
        with open(file_name, "r", encoding="utf-8", errors="ignore") as handle:
            for raw in handle:
                line = raw.strip()
                if not line:
                    continue
                parts = line.split(":")
                if len(parts) >= 4:
                    profile_id = self.next_id()
                    host, port, user = parts[0], parts[1], parts[2]
                    password = ":".join(parts[3:])
                    proxy = "http://%s:%s@%s:%s" % (
                        urllib.parse.quote(user, safe=""),
                        urllib.parse.quote(password, safe=""),
                        host,
                        port,
                    )
                    self.profiles.append({
                        "id": profile_id,
                        "name": "账号%s" % profile_id,
                        "group": "默认",
                        "proxy": proxy,
                        "note": "",
                        "pid": None,
                        "debugPort": next_debug_port(profile_id),
                    })
                    count += 1
        self.save_config()
        self.refresh_ui()
        self.set_status("已导入 %s 个代理配置。" % count)

    def start_proxy_if_needed(self, profile):
        parsed = parse_auth_proxy(profile.get("proxy", ""))
        if not parsed:
            return None
        local_port = 20000 + int(profile["id"])
        existing = self.local_proxies.get(int(profile["id"]))
        if existing:
            existing.stop()
        proxy = LocalAuthProxy(local_port, parsed)
        proxy.start()
        self.local_proxies[int(profile["id"])] = proxy
        return local_port

    def chrome_proxy_arg(self, profile):
        proxy = (profile.get("proxy") or "").strip()
        if not proxy:
            return None
        local_port = self.start_proxy_if_needed(profile)
        if local_port:
            return "http://127.0.0.1:%s" % local_port
        return normalize_proxy(proxy)

    def launch_profile(self, profile):
        if self.is_running(profile):
            return True
        if not self.chrome:
            messagebox.showerror("错误", "未找到 Google Chrome。请先安装 Chrome。")
            return False
        store_dir = profile_store_dir(profile)
        store_dir.mkdir(parents=True, exist_ok=True)
        args = [
            self.chrome,
            "--user-data-dir=%s" % store_dir,
            "--remote-debugging-port=%s" % int(profile["debugPort"]),
            "--no-first-run",
            "--no-default-browser-check",
        ]
        proxy_arg = self.chrome_proxy_arg(profile)
        if proxy_arg:
            args.append("--proxy-server=%s" % proxy_arg)
        try:
            proc = subprocess.Popen(args, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
            profile["pid"] = proc.pid
            for _ in range(30):
                time.sleep(0.2)
                if self.is_running(profile):
                    break
            self.save_config()
            self.update_badge(profile)
            return True
        except Exception as exc:
            messagebox.showerror("启动失败", str(exc))
            return False

    def stop_profile(self, profile):
        pid = pid_for_debug_port(profile["debugPort"]) or profile.get("pid")
        if pid:
            try:
                os.kill(int(pid), 15)
            except Exception:
                pass
            time.sleep(0.25)
            if port_open(profile["debugPort"]):
                try:
                    os.kill(int(pid), 9)
                except Exception:
                    pass
        proxy = self.local_proxies.pop(int(profile["id"]), None)
        if proxy:
            proxy.stop()
        profile["pid"] = None
        self.save_config()

    def launch_selected(self):
        selected = self.selected_profiles()
        if not selected:
            self.set_status("请先选中配置。")
            return
        for profile in selected:
            self.launch_profile(profile)
        self.refresh_ui(force_badges=True)

    def launch_all(self):
        count = 0
        for profile in self.profiles:
            if self.launch_profile(profile):
                count += 1
        self.refresh_ui(force_badges=True)
        self.set_status("已启动 %s 个配置。" % count)

    def stop_selected(self):
        selected = self.selected_profiles()
        for profile in selected:
            self.stop_profile(profile)
        self.refresh_ui()

    def stop_all(self):
        for profile in list(self.profiles):
            self.stop_profile(profile)
        self.refresh_ui()

    def toggle_selected(self):
        for profile in self.selected_profiles():
            if self.is_running(profile):
                self.stop_profile(profile)
            else:
                self.launch_profile(profile)
        self.refresh_ui(force_badges=True)

    def group_goto(self):
        url = self.url_var.get().strip()
        if not url:
            self.set_status("请输入地址。")
            return
        if not re.match(r"^https?://", url, re.I):
            url = "https://" + url
        count = 0
        for profile in self.target_profiles():
            if self.is_running(profile) and cdp_nav(profile["debugPort"], url):
                count += 1
        self.root.after(900, lambda: self.refresh_badges(force=True))
        self.set_status("群控跳转: 已向 %s 个窗口发送 -> %s" % (count, url))

    def group_exec(self):
        script = self.js_text.get("1.0", "end").strip()
        if not script:
            self.set_status("请输入脚本。")
            return
        count = 0
        for profile in self.target_profiles():
            if self.is_running(profile) and cdp_eval(profile["debugPort"], script):
                count += 1
        self.refresh_badges(force=True)
        self.set_status("群控执行: 已向 %s 个窗口执行脚本。" % count)

    def update_badge(self, profile):
        if not self.is_running(profile):
            return False
        configured_ip = proxy_host(profile.get("proxy", ""))
        expression = """
(function(){
  const badgeId = '__chrome_manager_window_badge';
  const windowNo = %s;
  const profileName = %s;
  const configuredIp = %s;
  const title = '窗口 #' + windowNo + (profileName ? '  ' + profileName : '');
  function ensureBadge(){
    let el = document.getElementById(badgeId);
    if (!el) {
      el = document.createElement('div');
      el.id = badgeId;
      (document.body || document.documentElement).appendChild(el);
    }
    el.style.cssText = [
      'position:fixed',
      'left:8px',
      'top:8px',
      'z-index:2147483647',
      'padding:5px 8px',
      'border-radius:6px',
      'background:rgba(17,24,39,.88)',
      'color:#fff',
      'border:1px solid rgba(255,255,255,.22)',
      'font:12px/1.35 Arial,Microsoft YaHei,sans-serif',
      'letter-spacing:0',
      'box-shadow:0 4px 14px rgba(0,0,0,.22)',
      'pointer-events:none',
      'white-space:nowrap'
    ].join(';');
    return el;
  }
  function setBadge(ip, source){
    ensureBadge().textContent = title + '  |  ' + source + ': ' + (ip || '未知');
  }
  setBadge(configuredIp || '检测中', configuredIp ? '配置IP' : '出口IP');
  fetch('https://api.ipify.org?format=json', { cache: 'no-store' })
    .then(function(r){ return r.json(); })
    .then(function(data){ if (data && data.ip) setBadge(data.ip, '出口IP'); })
    .catch(function(){ if (!configuredIp) setBadge('', '出口IP'); });
})();
""" % (int(profile["id"]), json.dumps(profile.get("name", ""), ensure_ascii=False), json.dumps(configured_ip, ensure_ascii=False))
        return cdp_eval(profile["debugPort"], expression)

    def refresh_badges(self, force=False):
        now = time.time()
        if not force and now - self.last_badge_at < 15:
            return
        self.last_badge_at = now
        for profile in self.profiles:
            if self.is_running(profile):
                self.update_badge(profile)

    def arrange_windows(self):
        running = [profile for profile in self.profiles if self.is_running(profile)]
        count = len(running)
        if count == 0:
            self.set_status("没有运行中的窗口。")
            return
        screen_w = max(self.root.winfo_screenwidth(), 900)
        screen_h = max(self.root.winfo_screenheight() - 80, 560)
        cols = max(1, int(math.ceil(math.sqrt(count * screen_w / screen_h))))
        rows = int(math.ceil(count / cols))
        width = int(screen_w / cols)
        height = int(screen_h / rows)
        script_lines = [
            'tell application "System Events"',
            'if exists process "Google Chrome" then',
            'tell process "Google Chrome"',
        ]
        for idx in range(count):
            x = (idx % cols) * width
            y = 40 + (idx // cols) * height
            win_idx = idx + 1
            script_lines.append('if (count of windows) >= %s then' % win_idx)
            script_lines.append('set position of window %s to {%s, %s}' % (win_idx, x, y))
            script_lines.append('set size of window %s to {%s, %s}' % (win_idx, width, height))
            script_lines.append('end if')
        script_lines.extend(["end tell", "end if", "end tell"])
        try:
            subprocess.run(["/usr/bin/osascript", "-e", "\n".join(script_lines)], check=True, stdout=subprocess.DEVNULL)
            self.set_status("已排列 %s 个 Chrome 窗口。" % count)
        except Exception as exc:
            messagebox.showinfo(
                "排列失败",
                "macOS 可能需要给 Python/终端开启辅助功能权限。\n系统设置 -> 隐私与安全性 -> 辅助功能。\n\n%s" % exc,
            )

    def tick(self):
        self.refresh_ui()
        self.refresh_badges()
        self.root.after(5000, self.tick)

    def on_close(self):
        for proxy in list(self.local_proxies.values()):
            proxy.stop()
        self.root.destroy()

    def run(self):
        self.root.mainloop()


if __name__ == "__main__":
    app = ChromeManagerApp()
    app.run()
