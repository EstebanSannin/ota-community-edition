#!/usr/bin/env python3
"""Lockbox + tooling support service.

Offline updates follow the standard Torizon workflow: the console creates the signed offline-update
roles (in the director), and `torizoncore-builder platform lockbox` pulls the container images and
assembles the removable-media bundle. This service exposes what that tooling needs, plus the lockbox
list for the console:

    GET  /api/lockboxes            -> JSON list of lockboxes (from the offline-snapshot role)
    POST /api/credentials          -> mint + stream credentials.zip (revokes the previous)
    GET/DELETE /api/credentials    -> current credential / revoke
    POST /tuf/oauth2/token[/token] -> client_credentials -> bearer token
    /tuf/* , /director/*           -> bearer-authenticated proxy to the reposerver / director,
                                      so torizoncore-builder can fetch metadata + push targets
"""
import base64, hashlib, hmac, http.server, io, json, os, re, secrets, sqlite3, threading, time
import urllib.error, urllib.parse, urllib.request, zipfile

DIRECTOR = os.environ.get("DIRECTOR_URL", "http://ota-lith:7300/api/v1")
REPOSERVER = os.environ.get("REPOSERVER_URL", "http://ota-lith:7100/api/v1")
REPOSERVER_ROOT = os.environ.get("REPOSERVER_ROOT", "http://ota-lith:7100")
DIRECTOR_ROOT = os.environ.get("DIRECTOR_ROOT", "http://ota-lith:7300")
TREEHUB_ROOT = os.environ.get("TREEHUB_ROOT", "http://ota-lith:7400")
KEYSERVER = os.environ.get("KEYSERVER_URL", "http://ota-lith:7200")
NAMESPACE = os.environ.get("OTA_NAMESPACE", "default")
PORT = int(os.environ.get("LOCKBOX_PORT", "9920"))


def fetch(url):
    req = urllib.request.Request(url, headers={"x-ats-namespace": NAMESPACE})
    with urllib.request.urlopen(req, timeout=30) as r:
        return r.read()


def lockbox_names():
    """Names come from the offline-snapshot role, which indexes every lockbox."""
    try:
        snap = json.loads(fetch(f"{DIRECTOR}/admin/repo/offline-snapshot.json"))
    except urllib.error.HTTPError as e:
        if e.code == 404:
            return []                      # none created yet
        raise
    meta = snap.get("signed", {}).get("meta", {})
    return sorted(n[:-5] for n in meta if n.endswith(".json"))


def lockbox_targets(name):
    role = json.loads(fetch(f"{DIRECTOR}/admin/repo/offline-updates/{name}.json"))
    signed = role.get("signed", {})
    return signed.get("targets", {}), signed.get("expires", "")




# ---------------------------------------------------------------------------
# Tooling credentials (credentials.zip) for torizoncore-builder / garage-sign.
#
# garage-sign only speaks two auth dialects (see repos/ota-tuf/cli … RepoManagement.scala):
# a client_credentials OAuth2 grant, or a client certificate. We implement the former, because
# the alternative that needs no server code — "no_auth": true — would leave an unauthenticated
# write path to the TUF repo on a public host.
#
# One credential per instance: minting a new one replaces (and so revokes) the old.
# Only a hash of the secret is stored, so the downloaded zip is the single copy.
DATA_DIR = os.environ.get("LOCKBOX_DATA_DIR", "/data")
TOKEN_TTL = int(os.environ.get("LOCKBOX_TOKEN_TTL", "3600"))
PUBLIC_URL = os.environ.get("PUBLIC_URL", "")           # e.g. https://ota.example.com
_tokens = {}                                            # token -> expiry (in-memory: a restart
_lock = threading.Lock()                                # just makes tooling re-authenticate)


def db():
    os.makedirs(DATA_DIR, exist_ok=True)
    con = sqlite3.connect(os.path.join(DATA_DIR, "lockbox.db"))
    con.execute("CREATE TABLE IF NOT EXISTS tuf_client "
                "(client_id TEXT PRIMARY KEY, secret_hash TEXT NOT NULL, created_at INTEGER)")
    return con


def hash_secret(secret):
    return hashlib.sha256(secret.encode()).hexdigest()


def mint_client():
    """Replace any existing credential with a fresh pair. Returns (client_id, secret)."""
    client_id, secret = secrets.token_hex(12), secrets.token_urlsafe(32)
    con = db()
    con.execute("DELETE FROM tuf_client")              # single credential per instance
    con.execute("INSERT INTO tuf_client VALUES (?,?,?)",
                (client_id, hash_secret(secret), int(time.time())))
    con.commit()
    con.close()
    return client_id, secret


def current_client():
    con = db()
    row = con.execute("SELECT client_id, created_at FROM tuf_client").fetchone()
    con.close()
    return {"client_id": row[0], "created_at": row[1]} if row else None


def verify_client(client_id, secret):
    con = db()
    row = con.execute("SELECT secret_hash FROM tuf_client WHERE client_id=?", (client_id,)).fetchone()
    con.close()
    return bool(row) and hmac.compare_digest(row[0], hash_secret(secret))


def issue_token():
    token = secrets.token_urlsafe(32)
    with _lock:
        now = time.time()
        for t in [t for t, exp in _tokens.items() if exp < now]:
            _tokens.pop(t, None)
        _tokens[token] = now + TOKEN_TTL
    return token


def valid_token(token):
    with _lock:
        return bool(token) and _tokens.get(token, 0) > time.time()


def credentials_zip(client_id, secret):
    """The zip garage-sign expects: treehub.json + tufrepo.url are required, the rest optional."""
    base = PUBLIC_URL.rstrip("/")
    treehub = {
        "no_auth": False,
        # A server URL ending in /token is POSTed directly with Basic client_id:client_secret
        # and grant_type=client_credentials (see OAuth2Client.scala).
        "oauth2": {"server": f"{base}/tuf/oauth2/token", "client_id": client_id,
                   "client_secret": secret, "scope": "tuf"},
        "ostree": {"server": f"{base}/treehub/api/v3/"},
    }
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w", zipfile.ZIP_DEFLATED) as z:
        z.writestr("treehub.json", json.dumps(treehub, indent=2))
        z.writestr("tufrepo.url", f"{base}/tuf")
        z.writestr("root.json", fetch(f"{REPOSERVER}/user_repo/root.json"))
        for name, field in (("targets.pub", "public"), ("targets.sec", "private")):
            z.writestr(name, json.dumps(target_key(field), indent=2))
    return buf.getvalue()


def target_key(field):
    """The targets keypair from the keyserver — this is what lets tooling sign targets."""
    repo_id = repo_id_of()
    keys = json.loads(fetch(f"{KEYSERVER}/api/v1/root/{repo_id}/keys/targets/pairs"))
    k = keys[0]
    return {"keytype": k["keytype"], "keyval": {field: k["keyval"][field]}}


def repo_id_of():
    req = urllib.request.Request(f"{REPOSERVER}/user_repo/root.json",
                                headers={"x-ats-namespace": NAMESPACE})
    with urllib.request.urlopen(req, timeout=30) as r:
        return r.headers["x-ats-tuf-repo-id"]


# Bearer-authenticated passthrough for tooling, keyed by URL prefix -> ota-lith backend:
#   /tuf/...       -> reposerver  (garage-sign + torizoncore-builder push/lockbox: image repo)
#   /director/...  -> director    (torizoncore-builder platform lockbox: offline-update roles)
#   /treehub/...   -> treehub     (OSTree object store: `platform push` of an OS/ostree commit)
# TCB derives the director URL from tufrepo.url by swapping the path to /director, and reads the
# treehub URL from treehub.json's ostree.server; we expose all three under the credentials.zip
# bearer and forward to the right internal service.
PROXY_BACKENDS = {"/tuf": REPOSERVER_ROOT, "/director": DIRECTOR_ROOT, "/treehub": TREEHUB_ROOT}


def proxy_prefix(path):
    for p in PROXY_BACKENDS:
        if path.startswith(p + "/"):
            return p
    return None


def proxy_to_ota(handler, path, method, prefix):
    token = ""
    auth = handler.headers.get("Authorization", "")
    if auth[:7].lower() == "bearer ":
        token = auth[7:].strip()
    if not valid_token(token):
        return handler._send(401, json.dumps({"error": "invalid or expired token"}))
    body = None
    n = int(handler.headers.get("Content-Length", "0") or 0)
    if n:
        body = handler.rfile.read(n)
    url = PROXY_BACKENDS[prefix] + path[len(prefix):]
    fwd = {"x-ats-namespace": NAMESPACE}
    for h in ("Content-Type", "x-ats-role-checksum"):
        if handler.headers.get(h):
            fwd[h] = handler.headers[h]
    req = urllib.request.Request(url, data=body, headers=fwd, method=method)
    try:
        with urllib.request.urlopen(req, timeout=120) as r:
            data, code, ctype = r.read(), r.status, r.headers.get("Content-Type", "application/json")
            extra = [("x-ats-role-checksum", r.headers["x-ats-role-checksum"])] \
                if r.headers.get("x-ats-role-checksum") else []
    except urllib.error.HTTPError as e:
        data, code, ctype, extra = e.read(), e.code, e.headers.get("Content-Type", "text/plain"), []
    handler._send(code, data, ctype, extra)


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        print("lockbox: " + (fmt % args), flush=True)

    def _send(self, code, body, ctype="application/json", extra=()):
        b = body.encode() if isinstance(body, str) else body
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(b)))
        for k, v in extra:
            self.send_header(k, v)
        self.end_headers()
        self.wfile.write(b)

    def do_GET(self):
        path = self.path.split("?")[0]
        if path in ("/api/health", "/health"):
            return self._send(200, json.dumps({"ok": True}))

        if path == "/api/lockboxes":
            try:
                out = []
                for n in lockbox_names():
                    targets, expires = lockbox_targets(n)
                    out.append({"name": n, "targets": sorted(targets), "expires": expires})
                return self._send(200, json.dumps({"values": out}))
            except Exception as e:
                return self._send(502, json.dumps({"error": str(e)}))

        if path == "/api/credentials":
            c = current_client()
            return self._send(200, json.dumps({"issued": c}))

        pfx = proxy_prefix(path)
        if pfx:
            return proxy_to_ota(self, self.path, "GET", pfx)       # keep the query string

        self._send(404, json.dumps({"error": "not found"}))


    # ---- writes: credential minting, the token endpoint, and tooling passthrough ----
    def do_POST(self):
        path = self.path.split("?")[0]
        if path == "/api/credentials":
            try:
                client_id, secret = mint_client()
                data = credentials_zip(client_id, secret)
            except Exception as e:
                return self._send(502, json.dumps({"error": str(e)}))
            print(f"lockbox: issued tooling credential {client_id} (previous one revoked)", flush=True)
            return self._send(200, data, "application/zip",
                              [("Content-Disposition", 'attachment; filename="credentials.zip"')])

        # garage-sign posts to the server value as-is (/tuf/oauth2/token); torizoncore-builder
        # appends "/token" to it, so accept the doubled path too. Same handler either way.
        if path in ("/tuf/oauth2/token", "/tuf/oauth2/token/token"):
            auth = self.headers.get("Authorization", "")
            if auth[:6].lower() != "basic ":
                return self._send(401, json.dumps({"error": "basic auth required"}))
            try:
                client_id, _, secret = base64.b64decode(auth[6:]).decode().partition(":")
            except Exception:
                return self._send(400, json.dumps({"error": "malformed credentials"}))
            n = int(self.headers.get("Content-Length", "0") or 0)
            if n:
                self.rfile.read(n)                     # grant_type=client_credentials, ignored
            if not verify_client(client_id, secret):
                print(f"lockbox: token denied for client {client_id[:8]}…", flush=True)
                return self._send(401, json.dumps({"error": "invalid_client"}))
            return self._send(200, json.dumps({"access_token": issue_token(),
                                               "token_type": "Bearer", "expires_in": TOKEN_TTL}))

        pfx = proxy_prefix(path)
        if pfx:
            return proxy_to_ota(self, self.path, "POST", pfx)     # keep the query string
        self._send(404, json.dumps({"error": "not found"}))

    def do_PUT(self):
        path = self.path.split("?")[0]
        pfx = proxy_prefix(path)
        if pfx:
            return proxy_to_ota(self, self.path, "PUT", pfx)      # keep the query string
        self._send(404, json.dumps({"error": "not found"}))

    def do_DELETE(self):
        path = self.path.split("?")[0]
        if path == "/api/credentials":
            con = db(); con.execute("DELETE FROM tuf_client"); con.commit(); con.close()
            with _lock:
                _tokens.clear()
            print("lockbox: tooling credential revoked", flush=True)
            return self._send(204, b"")
        pfx = proxy_prefix(path)
        if pfx:
            return proxy_to_ota(self, self.path, "DELETE", pfx)   # keep the query string
        self._send(404, json.dumps({"error": "not found"}))


if __name__ == "__main__":
    print(f"lockbox: listening on :{PORT}, director={DIRECTOR}, reposerver={REPOSERVER}", flush=True)
    http.server.ThreadingHTTPServer(("0.0.0.0", PORT), Handler).serve_forever()
