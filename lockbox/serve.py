#!/usr/bin/env python3
"""Lockbox exporter: packs an offline update (Torizon "Lockbox") into a .zip the browser downloads.

The director already signs the offline TUF roles; this service just collects everything a device
needs and lays it out the way aktualizr's OfflineUpdateFetcher expects:

    update/
      metadata/director/     root.json, offline-snapshot.json, <lockbox>.json
      metadata/image-repo/   root.json, snapshot.json, targets.json, timestamp.json
      images/                one file per target in the lockbox

so no torizoncore-builder (or any other external tool) is needed.

    GET /api/lockboxes                -> JSON list of lockboxes (name + target count)
    GET /api/lockbox/<name>.zip       -> the bundle
"""
import base64, hashlib, hmac, http.server, io, json, os, re, secrets, sqlite3, threading, time
import urllib.error, urllib.parse, urllib.request, zipfile

DIRECTOR = os.environ.get("DIRECTOR_URL", "http://ota-lith:7300/api/v1")
REPOSERVER = os.environ.get("REPOSERVER_URL", "http://ota-lith:7100/api/v1")
REPOSERVER_ROOT = os.environ.get("REPOSERVER_ROOT", "http://ota-lith:7100")
KEYSERVER = os.environ.get("KEYSERVER_URL", "http://ota-lith:7200")
NAMESPACE = os.environ.get("OTA_NAMESPACE", "default")
PORT = int(os.environ.get("LOCKBOX_PORT", "9920"))
# aktualizr's offline_updates_source points at this folder name (Toradex's documented default)
BUNDLE_DIR = os.environ.get("LOCKBOX_BUNDLE_DIR", "update")
SAFE_NAME = re.compile(r"^[A-Za-z0-9._-]{1,80}$")

IMAGE_REPO_ROLES = ("root.json", "snapshot.json", "targets.json", "timestamp.json")

README = """This is an offline update bundle (a "Lockbox") for Torizon OS.

Layout
------
  metadata/director/     signed offline TUF roles (the offline-snapshot indexes the lockboxes)
  metadata/image-repo/   image repository metadata
  images/                the update artifacts themselves

How to use it
-------------
1. Unzip onto removable media, keeping the "{bundle}" folder at its root, e.g. /media/usb/{bundle}
2. On the device, enable offline updates once by creating
   /etc/sota/conf.d/99-offline-updates.toml:

       [uptane]
       enable_offline_updates = true
       offline_updates_source = "/media/usb/{bundle}"

   (point offline_updates_source at wherever the folder is mounted)
3. Restart the client:  sudo systemctl restart aktualizr-torizon
   It logs "Offline Updates are enabled" when the setting is picked up.

Note: container images are NOT included in this bundle — the images/ folder holds the
targets stored on the OTA server (e.g. docker-compose files). A device installing a
container application still needs access to the registry for the image layers.
""".replace("{bundle}", BUNDLE_DIR)


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


def add_root_chain(z, dest, base, latest):
    """Write root.json plus every earlier version.

    A consumer only trusts a new root if it can walk the rotation chain from the version it
    already has, and the device's Secondaries may sit on an older root than the Primary — so
    ship 1.root.json … N.root.json, not just the latest.
    """
    z.writestr(f"{dest}/root.json", latest)
    version = json.loads(latest).get("signed", {}).get("version", 1)
    for v in range(1, version + 1):
        try:
            z.writestr(f"{dest}/{v}.root.json", fetch(f"{base}/{v}.root.json"))
        except urllib.error.HTTPError:
            pass                            # a gap in the chain is the server's business, not ours


def build_zip(name):
    targets, _ = lockbox_targets(name)
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w", zipfile.ZIP_DEFLATED) as z:
        d = f"{BUNDLE_DIR}/metadata/director"
        add_root_chain(z, d, f"{DIRECTOR}/admin/repo", fetch(f"{DIRECTOR}/admin/repo/root.json"))
        z.writestr(f"{d}/offline-snapshot.json", fetch(f"{DIRECTOR}/admin/repo/offline-snapshot.json"))
        z.writestr(f"{d}/{name}.json", fetch(f"{DIRECTOR}/admin/repo/offline-updates/{name}.json"))
        ir = f"{BUNDLE_DIR}/metadata/image-repo"
        add_root_chain(z, ir, f"{REPOSERVER}/user_repo", fetch(f"{REPOSERVER}/user_repo/root.json"))
        for role in IMAGE_REPO_ROLES:
            if role == "root.json":
                continue                    # already written with its chain above
            z.writestr(f"{ir}/{role}", fetch(f"{REPOSERVER}/user_repo/{role}"))
        for filename in targets:
            safe = filename.replace("..", "_").lstrip("/")
            z.writestr(f"{BUNDLE_DIR}/images/{safe}",
                       fetch(f"{REPOSERVER}/user_repo/targets/{urllib.parse.quote(filename)}"))
        z.writestr(f"{BUNDLE_DIR}/README.txt", README)
    return buf.getvalue()


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
        "ostree": {"server": f"{base}/tuf/api/v3/"},
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


def proxy_to_reposerver(handler, path, method):
    """Bearer-authenticated passthrough for tooling.

    tufrepo.url is <public>/tuf, and garage-sign appends /api/v1/user_repo/... to it, so strip
    the /tuf prefix and hand the rest to ota-lith with the namespace header it requires.
    """
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
    url = REPOSERVER_ROOT + path[len("/tuf"):]
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

        if path.startswith("/tuf/"):
            return proxy_to_reposerver(self, path, "GET")

        m = re.match(r"^/api/lockbox/(.+)\.zip$", path)
        if m:
            name = urllib.parse.unquote(m.group(1))
            if not SAFE_NAME.match(name):
                return self._send(400, json.dumps({"error": "invalid lockbox name"}))
            try:
                data = build_zip(name)
            except urllib.error.HTTPError as e:
                code = 404 if e.code == 404 else 502
                return self._send(code, json.dumps({"error": f"{name}: upstream {e.code}"}))
            except Exception as e:
                return self._send(502, json.dumps({"error": str(e)}))
            return self._send(200, data, "application/zip",
                              [("Content-Disposition", f'attachment; filename="{name}.zip"')])

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

        if path == "/tuf/oauth2/token":
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

        if path.startswith("/tuf/"):
            return proxy_to_reposerver(self, path, "POST")
        self._send(404, json.dumps({"error": "not found"}))

    def do_PUT(self):
        path = self.path.split("?")[0]
        if path.startswith("/tuf/"):
            return proxy_to_reposerver(self, self.path, "PUT")   # keep the query string
        self._send(404, json.dumps({"error": "not found"}))

    def do_DELETE(self):
        path = self.path.split("?")[0]
        if path == "/api/credentials":
            con = db(); con.execute("DELETE FROM tuf_client"); con.commit(); con.close()
            with _lock:
                _tokens.clear()
            print("lockbox: tooling credential revoked", flush=True)
            return self._send(204, b"")
        if path.startswith("/tuf/"):
            return proxy_to_reposerver(self, path, "DELETE")
        self._send(404, json.dumps({"error": "not found"}))


if __name__ == "__main__":
    print(f"lockbox: listening on :{PORT}, director={DIRECTOR}, reposerver={REPOSERVER}", flush=True)
    http.server.ThreadingHTTPServer(("0.0.0.0", PORT), Handler).serve_forever()
