#!/usr/bin/env python3
"""Tiny provisioning service: serves provision-device.sh and mints device credentials.
Mirrors Torizon Cloud's accounts/devices endpoint for the self-hosted CE."""
import http.server, subprocess, json, os, hmac, secrets, time, threading

APP = "/app"
# Static long-lived token (optional, back-compat). Prefer short-lived minted tokens below.
TOKEN = os.environ.get("PROVISION_TOKEN", "").strip()
# Require a token to enroll? True if a static token is set, or PROVISION_REQUIRE_TOKEN is truthy.
REQUIRE = bool(TOKEN) or os.environ.get("PROVISION_REQUIRE_TOKEN", "").strip().lower() not in ("", "0", "false", "no")
TTL = int(os.environ.get("PROVISION_TOKEN_TTL", "3600"))  # short-lived enrollment-token lifetime (s)
_minted = {}            # token -> expiry epoch (in-memory; a restart invalidates outstanding tokens)
_lock = threading.Lock()

def _prune():
    now = time.time()
    with _lock:
        for t in [t for t, e in _minted.items() if e < now]:
            _minted.pop(t, None)

def _mint():
    tok = secrets.token_urlsafe(9)
    exp = time.time() + TTL
    with _lock:
        _minted[tok] = exp
    _prune()
    return tok, exp

def _valid(supplied):
    if not supplied:
        return False
    if TOKEN and hmac.compare_digest(supplied, TOKEN):
        return True
    _prune()
    with _lock:
        return supplied in _minted and _minted[supplied] > time.time()

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
        p = self.path.split("?")[0]
        if p == "/api/provision-tokens":       # operator mints a short-lived enrollment token
            tok, exp = _mint()                 # (this path is gated by the console password at the proxy)
            self._send(200, json.dumps({"token": tok, "expires_at": int(exp), "ttl_secs": TTL}))
            return
        if p == "/api/provision":
            if REQUIRE:
                auth = self.headers.get("Authorization", "")
                supplied = auth[7:].strip() if auth[:7].lower() == "bearer " else self.headers.get("X-Provision-Token", "").strip()
                if not _valid(supplied):
                    self._send(401, json.dumps({"error": "invalid or expired provisioning token"}))
                    return
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
