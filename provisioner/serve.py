#!/usr/bin/env python3
"""Tiny provisioning service: serves provision-device.sh and mints device credentials.
Mirrors Torizon Cloud's accounts/devices endpoint for the self-hosted CE."""
import http.server, subprocess, json

APP = "/app"

class Handler(http.server.BaseHTTPRequestHandler):
    def _send(self, code, body, ctype="application/json"):
        b = body.encode() if isinstance(body, str) else body
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(b)))
        self.end_headers()
        self.wfile.write(b)

    def log_message(self, fmt, *args):  # quieter logs
        print("provisioner: " + (fmt % args), flush=True)

    def do_GET(self):
        if self.path.split("?")[0] == "/provision-device.sh":
            with open(f"{APP}/provision-device.sh", "rb") as f:
                self._send(200, f.read(), "text/x-shellscript")
        else:
            self._send(404, "not found\n", "text/plain")

    def do_POST(self):
        if self.path.split("?")[0] == "/api/provision":
            n = int(self.headers.get("Content-Length", "0") or 0)
            raw = self.rfile.read(n) if n else b""
            name = ""
            try:
                name = (json.loads(raw or "{}").get("name") or "").strip()
            except Exception:
                pass
            try:
                r = subprocess.run([f"{APP}/mint.sh", name], capture_output=True, text=True, timeout=60)
                if r.returncode != 0:
                    self._send(500, json.dumps({"error": (r.stderr or "mint failed")[-800:]}))
                    return
                self._send(200, r.stdout)
            except Exception as e:
                self._send(500, json.dumps({"error": str(e)}))
        else:
            self._send(404, "not found\n", "text/plain")

if __name__ == "__main__":
    http.server.ThreadingHTTPServer(("0.0.0.0", 9900), Handler).serve_forever()
