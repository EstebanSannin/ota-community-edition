#!/usr/bin/env python3
"""Read-only ops sidecar: container status + resources + live logs for the console's System page.

Talks to a read-only docker-socket-proxy (never the raw socket), so it can only *read* Docker.
Two endpoints, both meant to sit behind the console password at the proxy:

    GET /api/status          -> JSON: per-container state + cpu/mem, totals, docker disk usage
    GET /api/logs?name=<c>   -> Server-Sent Events stream of that container's logs (follow)
"""
import http.server, json, os, shutil, struct, time, urllib.request
from concurrent.futures import ThreadPoolExecutor

DOCKER = os.environ.get("DOCKER_HOST_HTTP", "http://socket-proxy:2375").rstrip("/")
PROJECT = os.environ.get("COMPOSE_PROJECT", "ota-community-edition")
PORT = int(os.environ.get("OPS_PORT", "9910"))
DF_TTL = 30  # seconds to cache the (slowish) docker disk-usage call


def docker_get(path, timeout=15):
    """GET a Docker Engine API path through the socket proxy, decoding JSON."""
    with urllib.request.urlopen(f"{DOCKER}{path}", timeout=timeout) as r:
        return json.loads(r.read())


def cpu_percent(s):
    """Docker's own CPU% formula, from a single stats snapshot."""
    try:
        cpu, pre = s["cpu_stats"], s["precpu_stats"]
        cpu_delta = cpu["cpu_usage"]["total_usage"] - pre["cpu_usage"]["total_usage"]
        sys_delta = cpu["system_cpu_usage"] - pre["system_cpu_usage"]
        ncpu = cpu.get("online_cpus") or len(cpu["cpu_usage"].get("percpu_usage") or [1])
        return round(cpu_delta / sys_delta * ncpu * 100, 1) if sys_delta > 0 else 0.0
    except (KeyError, TypeError, ZeroDivisionError):
        return 0.0


def mem_bytes(s):
    """Used memory the way `docker stats` reports it: usage minus reclaimable page cache."""
    m = s.get("memory_stats", {})
    return max(0, m.get("usage", 0) - m.get("stats", {}).get("inactive_file", 0))


def container_stat(c):
    """One row for /api/status: name, compose service, state, and live cpu/mem."""
    name = c["Names"][0].lstrip("/")
    row = {
        "name": name,
        "service": c.get("Labels", {}).get("com.docker.compose.service", name),
        "state": c.get("State", "unknown"),        # running | exited | ...
        "status": c.get("Status", ""),             # e.g. "Up 2 hours (healthy)"
        "cpu": 0.0, "mem_mb": 0,
    }
    if row["state"] == "running":
        try:
            s = docker_get(f"/containers/{name}/stats?stream=false")
            row["cpu"] = cpu_percent(s)
            row["mem_mb"] = round(mem_bytes(s) / 1048576)
        except Exception:
            pass
    return row


def our_containers():
    """All containers in this compose project (running or not)."""
    cs = docker_get("/containers/json?all=1")
    return [c for c in cs if c.get("Labels", {}).get("com.docker.compose.project") == PROJECT]


_df_cache = {"at": 0, "val": None}


def docker_disk():
    """Docker's own disk footprint (images + volumes + build cache), cached briefly."""
    if _df_cache["val"] and time.time() - _df_cache["at"] < DF_TTL:
        return _df_cache["val"]
    try:
        df = docker_get("/system/df", timeout=30)
        images = df.get("LayersSize", 0)
        volumes = sum((v.get("UsageData") or {}).get("Size", 0) for v in df.get("Volumes") or [])
        build = sum(b.get("Size", 0) for b in df.get("BuildCache") or [])
        val = {"images_mb": round(images / 1048576), "volumes_mb": round(volumes / 1048576),
               "build_cache_mb": round(build / 1048576),
               "total_mb": round((images + volumes + build) / 1048576)}
    except Exception:
        val = {"images_mb": 0, "volumes_mb": 0, "build_cache_mb": 0, "total_mb": 0}
    _df_cache.update(at=time.time(), val=val)
    return val


def host_disk():
    """Real host filesystem usage. The container root is an overlay on the host disk, so its
    statvfs reports the backing filesystem (the VPS's main disk)."""
    total, used, free = shutil.disk_usage("/")
    return {"total_mb": round(total / 1048576), "used_mb": round(used / 1048576),
            "free_mb": round(free / 1048576), "pct": round(used / total * 100) if total else 0}


def build_status():
    containers = our_containers()
    with ThreadPoolExecutor(max_workers=8) as pool:
        rows = sorted(pool.map(container_stat, containers), key=lambda r: r["service"])
    info = docker_get("/info")   # host facts: os, kernel, arch, cpu, memory (no host mount needed)
    up = sum(1 for r in rows if r["state"] == "running")
    return {
        "services": rows,
        "totals": {
            "up": up, "total": len(rows),
            "cpu": round(sum(r["cpu"] for r in rows), 1),
            "mem_used_mb": sum(r["mem_mb"] for r in rows),
            "mem_total_mb": round(info.get("MemTotal", 0) / 1048576),
        },
        "host": {
            "hostname": info.get("Name", ""),
            "os": info.get("OperatingSystem", ""),
            "kernel": info.get("KernelVersion", ""),
            "arch": info.get("Architecture", ""),
            "cpus": info.get("NCPU", 0),
            "docker": info.get("ServerVersion", ""),
        },
        "disk": host_disk(),
        "docker_disk": docker_disk(),
    }


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        print("ops: " + (fmt % args), flush=True)

    def _json(self, code, obj):
        b = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(b)))
        self.end_headers()
        self.wfile.write(b)

    def do_GET(self):
        path = self.path.split("?")[0]
        if path in ("/api/health", "/health"):
            self._json(200, {"ok": True})
        elif path == "/api/status":
            try:
                self._json(200, build_status())
            except Exception as e:
                self._json(502, {"error": f"docker unreachable: {e}"})
        elif path == "/api/logs":
            self.stream_logs()
        else:
            self._json(404, {"error": "not found"})

    # ---- live logs as Server-Sent Events ----
    def stream_logs(self):
        from urllib.parse import parse_qs, urlparse
        q = parse_qs(urlparse(self.path).query)
        name = (q.get("name") or [""])[0]
        tail = (q.get("tail") or ["200"])[0]
        allowed = {c["Names"][0].lstrip("/") for c in our_containers()}
        if name not in allowed:                     # only ever stream this project's containers
            self._json(403, {"error": "unknown container"})
            return
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-cache")
        self.send_header("X-Accel-Buffering", "no")  # ask nginx not to buffer
        self.end_headers()
        url = (f"{DOCKER}/containers/{name}/logs"
               f"?follow=1&stdout=1&stderr=1&timestamps=1&tail={int(tail) if tail.isdigit() else 200}")
        try:
            with urllib.request.urlopen(url, timeout=None) as up:
                for line in demux(up):
                    self.wfile.write(b"data: " + line.replace(b"\n", b"") + b"\n\n")
                    self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError):
            pass                                    # browser closed the tab
        except Exception as e:
            try:
                self.wfile.write(b"data: [ops] log stream ended: " + str(e).encode() + b"\n\n")
            except Exception:
                pass


def demux(stream):
    """Yield log lines from Docker's multiplexed log stream (8-byte frame headers).

    Non-TTY containers get a header per frame: [stream(1), 0,0,0, size(4, big-endian)] + payload.
    TTY containers send raw bytes; we fall back to line-splitting if the header looks wrong.
    """
    buf = b""
    while True:
        header = stream.read(8)
        if not header:
            return
        if len(header) == 8 and header[0] in (0, 1, 2) and header[1:4] == b"\x00\x00\x00":
            size = struct.unpack(">I", header[4:8])[0]
            payload = read_exact(stream, size)
            buf += payload
        else:                                        # not a frame header -> raw TTY stream
            buf += header + stream.read(4096)
        while b"\n" in buf:
            line, buf = buf.split(b"\n", 1)
            yield line


def read_exact(stream, n):
    out = b""
    while len(out) < n:
        chunk = stream.read(n - len(out))
        if not chunk:
            break
        out += chunk
    return out


if __name__ == "__main__":
    print(f"ops: listening on :{PORT}, docker via {DOCKER}, project {PROJECT}", flush=True)
    http.server.ThreadingHTTPServer(("0.0.0.0", PORT), Handler).serve_forever()
