#!/usr/bin/env python3
# =============================================================================
# server.py  -  web control panel for GM Encoder (stdlib only).
# Talks to the bash watch/encode side purely through JSON files in CONFIG_DIR.
# =============================================================================
import json, os, re, subprocess, time, threading, shutil
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs

CONFIG_DIR = os.environ.get("CONFIG_DIR", "/config")
INPUT_DIR  = os.environ.get("INPUT_DIR", "/input")
OUTPUT_DIR = os.environ.get("OUTPUT_DIR", "/output")
PORT       = int(os.environ.get("GUI_PORT", "8080"))
WEBUI_DIR  = "/app/webui"

SETTINGS = os.path.join(CONFIG_DIR, "settings.json")
RUNTIME  = os.path.join(CONFIG_DIR, "runtime.json")
STATUS   = os.path.join(CONFIG_DIR, "status.json")
QUEUE    = os.path.join(CONFIG_DIR, "queue.json")
HISTORY  = os.path.join(CONFIG_DIR, "history.jsonl")
LOGFILE  = os.path.join(CONFIG_DIR, "gm-encoder.log")
STOPFLAG = os.path.join(CONFIG_DIR, "stop_current")

VIDEO_EXT = (".mp4", ".mkv", ".mov", ".avi", ".m4v", ".webm", ".ts", ".wmv", ".flv")

# key -> (label, kind, options, env-default)
SCHEMA = [
    ("CODEC", "Codec / GPU", "select",
     ["auto","nvidia","intel","amd","cpu",
      "hevc_nvenc","av1_nvenc","h264_nvenc","hevc_qsv","av1_qsv","h264_qsv",
      "hevc_vaapi","av1_vaapi","h264_vaapi","libx265","libsvtav1","libx264"], "auto"),
    ("FAMILY", "Family (nvidia/intel/amd/cpu/auto)", "select", ["hevc","av1","h264"], "hevc"),
    ("OPTIMIZE", "Optimize (VMAF search)", "select", ["true","false"], "true"),
    ("VMAF_TARGET", "VMAF minimum (accept >= this)", "number", None, "93"),
    ("INITIAL_CRF", "Initial CRF", "number", None, "22"),
    ("MIN_CRF", "Min CRF (worst)", "number", None, "28"),
    ("MAX_CRF", "Max CRF (best)", "number", None, "18"),
    ("MANUAL_CRF", "Manual CRF/QP", "number", None, "23"),
    ("HEIGHT", "Scale height (0=source)", "number", None, "0"),
    ("REMUX", "Remux original streams", "select", ["true","false"], "true"),
    ("OUTPUT_CONTAINER", "Output container", "select", ["mkv","mp4"], "mkv"),
    ("OUTPUT_SUFFIX", "Output suffix", "text", None, "_gm"),
    ("OUTPUT_SUBDIR", "Output subdir", "text", None, "SAME_AS_SRC"),
    ("SOURCE_ACTION", "After success", "select", ["move","keep","delete"], "move"),
    ("KEEP_LARGER", "Keep output even if bigger", "select", ["true","false"], "true"),
    ("GPU_BUSY_WAIT", "Wait if GPU is busy", "select", ["false","true"], "false"),
    ("GPU_BUSY_UTIL", "GPU-busy util % (wait above)", "number", None, "40"),
    ("GPU_BUSY_VRAM", "GPU-busy VRAM % (wait above)", "number", None, "50"),
    ("WATCH_ENABLED", "Auto watch-folder", "select", ["true","false"], "true"),
    ("WATCH_INTERVAL", "Poll interval (s)", "number", None, "15"),
    ("FILE_STABLE_SECONDS", "File stable (s)", "number", None, "20"),
    ("SCAN_EXISTING", "Scan existing on start", "select", ["true","false"], "true"),
    ("INPUT_EXTENSIONS", "Input extensions", "text", None, "mp4,mkv,mov,avi,m4v,webm,ts,wmv,flv"),
]
KEYS = [s[0] for s in SCHEMA]

# ---------- helpers ----------
def read_json(path, default):
    try:
        with open(path) as f:
            return json.load(f)
    except Exception:
        return default

def write_json_atomic(path, obj):
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        json.dump(obj, f)
    os.replace(tmp, path)

def eff_settings():
    saved = read_json(SETTINGS, {})
    out = {}
    for key, label, kind, opts, dflt in SCHEMA:
        val = saved.get(key)
        if val is None or val == "":
            val = os.environ.get(key, dflt)
        out[key] = str(val)
    return out

def tail(path, n):
    try:
        with open(path, "r", errors="replace") as f:
            return f.readlines()[-n:]
    except Exception:
        return []

def list_input():
    items = []
    for root, _, files in os.walk(INPUT_DIR):
        if os.path.basename(root) == "done":
            continue
        for fn in sorted(files):
            if fn.lower().endswith(VIDEO_EXT):
                full = os.path.join(root, fn)
                try:
                    sz = os.path.getsize(full)
                except OSError:
                    sz = 0
                items.append({"path": full,
                              "rel": os.path.relpath(full, INPUT_DIR),
                              "size_mb": round(sz / 1048576, 1)})
    return items[:500]

def list_outputs():
    items = []
    for root, _, files in os.walk(OUTPUT_DIR):
        for fn in sorted(files):
            if fn.startswith(".") or fn.endswith(".part"):
                continue
            full = os.path.join(root, fn)
            try:
                sz = os.path.getsize(full)
            except OSError:
                sz = 0
            items.append({"rel": os.path.relpath(full, OUTPUT_DIR),
                          "size_mb": round(sz / 1048576, 1)})
    return items[:500]

_cpu_prev = {"t": None}
def cpu_pct():
    def snap():
        with open("/proc/stat") as f:
            p = f.readline().split()[1:]
        p = list(map(int, p))
        idle = p[3] + p[4]
        return sum(p), idle
    try:
        total1, idle1 = snap(); time.sleep(0.12); total2, idle2 = snap()
        dt, di = total2 - total1, idle2 - idle1
        return round(100 * (dt - di) / dt, 1) if dt > 0 else 0.0
    except Exception:
        return None

def gpu_pct():
    exe = shutil.which("nvidia-smi")
    if exe:
        try:
            out = subprocess.run([exe, "--query-gpu=utilization.gpu",
                                  "--format=csv,noheader,nounits"],
                                 capture_output=True, text=True, timeout=3)
            v = out.stdout.strip().splitlines()
            if v:
                return float(v[0].strip())
        except Exception:
            pass
    for card in ("card0", "card1"):
        p = f"/sys/class/drm/{card}/device/gpu_busy_percent"
        try:
            with open(p) as f:
                return float(f.read().strip())
        except Exception:
            continue
    return None

def history_recent(limit):
    out = []
    for line in tail(HISTORY, limit):
        line = line.strip()
        if line:
            try: out.append(json.loads(line))
            except Exception: pass
    out.reverse()
    return out

# ---------- HTTP ----------
class H(BaseHTTPRequestHandler):
    def log_message(self, *a):  # quiet
        pass

    def _send(self, code, body, ctype="application/json"):
        if isinstance(body, (dict, list)):
            body = json.dumps(body).encode()
        elif isinstance(body, str):
            body = body.encode()
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _body(self):
        n = int(self.headers.get("Content-Length", 0) or 0)
        try:
            return json.loads(self.rfile.read(n) or b"{}")
        except Exception:
            return {}

    def do_GET(self):
        u = urlparse(self.path); path = u.path; q = parse_qs(u.query)
        if path in ("/", "/index.html"):
            return self._serve_static("index.html")
        if path == "/api/status":
            st = read_json(STATUS, {"state": "idle"})
            st["queue"] = read_json(QUEUE, [])
            st["paused"] = bool(read_json(RUNTIME, {}).get("paused", False))
            st["cpu"] = cpu_pct()
            st["gpu"] = gpu_pct()
            st["input_count"] = len(list_input())
            st["history"] = history_recent(15)
            st["ts"] = int(time.time())
            return self._send(200, st)
        if path == "/api/settings":
            return self._send(200, {"values": eff_settings(),
                                    "schema": [{"key": k, "label": l, "kind": kd, "options": o}
                                               for (k, l, kd, o, _) in SCHEMA]})
        if path == "/api/files":
            return self._send(200, {"input": list_input(), "input_dir": INPUT_DIR})
        if path == "/api/outputs":
            return self._send(200, {"outputs": list_outputs()})
        if path == "/api/download":
            rel = q.get("file", [""])[0]
            full = os.path.realpath(os.path.join(OUTPUT_DIR, rel))
            if not full.startswith(os.path.realpath(OUTPUT_DIR)) or not os.path.isfile(full):
                return self._send(404, {"error": "not found"})
            try:
                fsize = os.path.getsize(full)
                self.send_response(200)
                self.send_header("Content-Type", "application/octet-stream")
                self.send_header("Content-Disposition", f'attachment; filename="{os.path.basename(full)}"')
                self.send_header("Content-Length", str(fsize))
                self.end_headers()
                with open(full, "rb") as f:
                    while True:
                        chunk = f.read(1 << 20)
                        if not chunk:
                            break
                        self.wfile.write(chunk)
            except (BrokenPipeError, ConnectionResetError):
                pass
            return
        if path == "/api/log":
            n = int((q.get("lines", ["200"])[0]))
            return self._send(200, {"lines": [l.rstrip("\n") for l in tail(LOGFILE, n)]})
        if path == "/api/history":
            n = int((q.get("limit", ["50"])[0]))
            return self._send(200, {"history": history_recent(n)})
        if path.startswith("/static/"):
            return self._serve_static(path[len("/static/"):])
        return self._send(404, {"error": "not found"})

    def do_POST(self):
        u = urlparse(self.path); path = u.path
        if path == "/api/upload":
            name = os.path.basename(parse_qs(u.query).get("name", [""])[0])
            if not name or name.startswith("."):
                return self._send(400, {"error": "bad name"})
            os.makedirs(INPUT_DIR, exist_ok=True)
            dest = os.path.join(INPUT_DIR, name)
            n = int(self.headers.get("Content-Length", 0) or 0)
            written = 0
            try:
                with open(dest + ".part", "wb") as f:
                    remaining = n
                    while remaining > 0:
                        chunk = self.rfile.read(min(1 << 20, remaining))
                        if not chunk:
                            break
                        f.write(chunk); remaining -= len(chunk); written += len(chunk)
                os.replace(dest + ".part", dest)
            except Exception as e:
                try: os.remove(dest + ".part")
                except OSError: pass
                return self._send(500, {"error": str(e)})
            return self._send(200, {"ok": True, "name": name, "bytes": written})
        if path == "/api/settings":
            body = self._body()
            saved = read_json(SETTINGS, {})
            for k, v in body.items():
                if k in KEYS:
                    saved[k] = str(v)
            write_json_atomic(SETTINGS, saved)
            return self._send(200, {"ok": True, "values": eff_settings()})
        if path == "/api/encode":
            body = self._body()
            f = body.get("file", "")
            full = os.path.realpath(os.path.join(INPUT_DIR, f)) if not os.path.isabs(f) else os.path.realpath(f)
            if not full.startswith(os.path.realpath(INPUT_DIR)) or not os.path.isfile(full):
                return self._send(400, {"error": "file not under input dir"})
            qn = read_json(QUEUE, [])
            if full not in qn:
                qn.append(full); write_json_atomic(QUEUE, qn)
            return self._send(200, {"ok": True, "queued": full})
        if path == "/api/control":
            action = self._body().get("action", "")
            rt = read_json(RUNTIME, {"paused": False})
            if action == "pause":
                rt["paused"] = True; write_json_atomic(RUNTIME, rt)
            elif action == "resume":
                rt["paused"] = False; write_json_atomic(RUNTIME, rt)
            elif action == "stop":
                open(STOPFLAG, "w").close()
                for name in ("ffmpeg", "dynamic-crf"):
                    subprocess.run(["pkill", "-TERM", name],
                                   stderr=subprocess.DEVNULL, stdout=subprocess.DEVNULL)
                time.sleep(0.8)
                for name in ("ffmpeg", "dynamic-crf"):
                    subprocess.run(["pkill", "-KILL", name],
                                   stderr=subprocess.DEVNULL, stdout=subprocess.DEVNULL)
            elif action == "clear_queue":
                write_json_atomic(QUEUE, [])
            else:
                return self._send(400, {"error": "unknown action"})
            return self._send(200, {"ok": True})
        return self._send(404, {"error": "not found"})

    def _serve_static(self, rel):
        rel = rel.lstrip("/")
        full = os.path.realpath(os.path.join(WEBUI_DIR, rel))
        if not full.startswith(os.path.realpath(WEBUI_DIR)) or not os.path.isfile(full):
            return self._send(404, {"error": "not found"})
        ctype = "text/html" if full.endswith(".html") else \
                "application/javascript" if full.endswith(".js") else \
                "text/css" if full.endswith(".css") else "application/octet-stream"
        with open(full, "rb") as f:
            self._send(200, f.read(), ctype)

if __name__ == "__main__":
    os.makedirs(CONFIG_DIR, exist_ok=True)
    print(f"[server] GM Encoder web GUI on :{PORT}", flush=True)
    ThreadingHTTPServer(("0.0.0.0", PORT), H).serve_forever()
