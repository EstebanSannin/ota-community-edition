#!/usr/bin/env python3
"""Local user management + login for the console — the offline-capable alternative to GitHub sign-in.

The console itself knows nothing about users; all login lives in the front layer. Caddy delegates to
this service with `forward_auth`: every request first hits /auth/verify, and only proceeds if a valid
session cookie is present. Unauthenticated browsers are bounced to /login; unauthenticated API calls
get a 401.

This is deliberately small and stdlib-only (same shape as lockbox/ops/provisioner). It is meant for a
single-tenant admin console behind TLS — not a public signup system.

    GET  /auth/verify              forward_auth hook: 2xx = allow, else 302 /login (browser) or 401
    GET  /login                    login form
    POST /login                    username+password -> session cookie -> redirect
    POST /logout                   clear the session
    GET  /auth/api/me              { username } of the current session
    GET  /auth/api/users           list users            (session required)
    POST /auth/api/users           create { username, password }        (session required)
    POST /auth/api/users/<u>/password   reset { password }              (session required)
    DELETE /auth/api/users/<u>     delete a user (purges their sessions) (session required)

Passwords are scrypt-hashed with a per-user salt. Sessions live in memory (a restart just forces
re-login) and are purged immediately when a user is deleted, disabled, or has their password reset.
"""
import http.cookies, http.server, json, hashlib, hmac, os, re, secrets, sqlite3, threading, time
import urllib.parse

PORT = int(os.environ.get("AUTH_PORT", "9930"))
DATA_DIR = os.environ.get("AUTH_DATA_DIR", "/data")
SESSION_TTL = int(os.environ.get("AUTH_SESSION_TTL", "43200"))     # 12h
COOKIE = os.environ.get("AUTH_COOKIE_NAME", "ota_session")
# Secure cookies are HTTPS-only. Default on (the front is Caddy/TLS); set 0 only for plain-HTTP tests.
COOKIE_SECURE = os.environ.get("AUTH_COOKIE_SECURE", "1") != "0"
SAFE_USER = re.compile(r"^[A-Za-z0-9._-]{1,64}$")

# Password hashing. scrypt is preferred (memory-hard); we tag the stored hash with the algorithm so
# verify always uses the right one and the format can evolve. Some stdlib builds (e.g. LibreSSL on
# macOS) ship no scrypt, so fall back to a high-iteration PBKDF2 there. The deployment image
# (python:3.12-slim, OpenSSL) always has scrypt.
_N, _R, _P = 2 ** 14, 8, 1
_MAXMEM = 128 * _N * _R * 2
_PBKDF2_ITERS = 600_000


def _has_scrypt():
    try:
        hashlib.scrypt(b"x", salt=b"x", n=2, r=1, p=1, dklen=16, maxmem=0)
        return True
    except Exception:
        return False


_SCRYPT = _has_scrypt()

# Failed-login throttle: after MAX_FAILS within WINDOW seconds for one username, reject briefly.
MAX_FAILS = int(os.environ.get("AUTH_MAX_FAILS", "5"))
FAIL_WINDOW = int(os.environ.get("AUTH_FAIL_WINDOW", "300"))

_sessions = {}          # token -> {"user": str, "exp": float}
_fails = {}             # username -> [timestamps of recent failures]
_lock = threading.Lock()


# ---- storage ----
def db():
    os.makedirs(DATA_DIR, exist_ok=True)
    con = sqlite3.connect(os.path.join(DATA_DIR, "auth.db"))
    con.execute("CREATE TABLE IF NOT EXISTS users "
                "(username TEXT PRIMARY KEY, pw_hash TEXT NOT NULL, salt TEXT NOT NULL, "
                " created_at INTEGER NOT NULL, disabled INTEGER NOT NULL DEFAULT 0)")
    return con


def hash_pw(password, salt_hex):
    salt = bytes.fromhex(salt_hex)
    if _SCRYPT:
        dk = hashlib.scrypt(password.encode(), salt=salt, n=_N, r=_R, p=_P, dklen=32, maxmem=_MAXMEM)
        return "scrypt:" + dk.hex()
    dk = hashlib.pbkdf2_hmac("sha256", password.encode(), salt, _PBKDF2_ITERS, dklen=32)
    return "pbkdf2:" + dk.hex()


def verify_hash(password, salt_hex, stored):
    algo, _, h = stored.partition(":")
    salt = bytes.fromhex(salt_hex)
    if algo == "scrypt":
        calc = hashlib.scrypt(password.encode(), salt=salt, n=_N, r=_R, p=_P, dklen=32, maxmem=_MAXMEM).hex()
    else:
        calc = hashlib.pbkdf2_hmac("sha256", password.encode(), salt, _PBKDF2_ITERS, dklen=32).hex()
    return hmac.compare_digest(calc, h)


def set_user(username, password):
    salt = secrets.token_hex(16)
    con = db()
    con.execute("INSERT OR REPLACE INTO users (username, pw_hash, salt, created_at, disabled) "
                "VALUES (?,?,?,COALESCE((SELECT created_at FROM users WHERE username=?),?),0)",
                (username, hash_pw(password, salt), salt, username, int(time.time())))
    con.commit()
    con.close()
    purge_sessions(username)                 # any old sessions must not survive a password change


def list_users():
    con = db()
    rows = con.execute("SELECT username, created_at, disabled FROM users ORDER BY username").fetchall()
    con.close()
    return [{"username": u, "created_at": c, "disabled": bool(d)} for u, c, d in rows]


def user_count():
    con = db()
    n = con.execute("SELECT COUNT(*) FROM users WHERE disabled=0").fetchone()[0]
    con.close()
    return n


def delete_user(username):
    con = db()
    con.execute("DELETE FROM users WHERE username=?", (username,))
    con.commit()
    con.close()
    purge_sessions(username)


def verify_pw(username, password):
    con = db()
    row = con.execute("SELECT pw_hash, salt, disabled FROM users WHERE username=?", (username,)).fetchone()
    con.close()
    if not row or row[2]:
        return False
    return verify_hash(password, row[1], row[0])


# ---- sessions ----
def new_session(username):
    token = secrets.token_urlsafe(32)
    with _lock:
        now = time.time()
        for t in [t for t, s in _sessions.items() if s["exp"] < now]:
            _sessions.pop(t, None)
        _sessions[token] = {"user": username, "exp": now + SESSION_TTL}
    return token


def session_user(token):
    with _lock:
        s = _sessions.get(token or "")
        if s and s["exp"] > time.time():
            return s["user"]
        return None


def drop_session(token):
    with _lock:
        _sessions.pop(token or "", None)


def purge_sessions(username):
    with _lock:
        for t in [t for t, s in _sessions.items() if s["user"] == username]:
            _sessions.pop(t, None)


# ---- throttle ----
def throttled(username):
    with _lock:
        now = time.time()
        hits = [t for t in _fails.get(username, []) if t > now - FAIL_WINDOW]
        _fails[username] = hits
        return len(hits) >= MAX_FAILS


def record_fail(username):
    with _lock:
        _fails.setdefault(username, []).append(time.time())


def clear_fails(username):
    with _lock:
        _fails.pop(username, None)


# ---- bootstrap: never leave the instance with no way in ----
def ensure_admin():
    if user_count() > 0:
        return
    user = os.environ.get("AUTH_ADMIN_USER", "admin")
    pw = os.environ.get("AUTH_ADMIN_PASSWORD") or secrets.token_urlsafe(12)
    set_user(user, pw)
    if os.environ.get("AUTH_ADMIN_PASSWORD"):
        print(f"auth: created initial user '{user}' from AUTH_ADMIN_PASSWORD", flush=True)
    else:
        print("auth: no users existed - created an initial administrator:", flush=True)
        print(f"auth:     username: {user}", flush=True)
        print(f"auth:     password: {pw}", flush=True)
        print("auth: log in and change it from the Users page; this is shown only once.", flush=True)


LOGIN_PAGE = """<!doctype html><html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Sign in</title><style>
:root{color-scheme:light dark}
body{font:15px/1.5 system-ui,sans-serif;margin:0;min-height:100vh;display:grid;place-items:center;background:#f5f6f8}
@media(prefers-color-scheme:dark){body{background:#15171c}}
form{background:#fff;padding:28px 26px;border-radius:14px;box-shadow:0 8px 30px rgba(0,0,0,.12);width:300px}
@media(prefers-color-scheme:dark){form{background:#1e2128;box-shadow:none;border:1px solid #2a2e37}}
h1{font-size:18px;margin:0 0 4px}p.s{margin:0 0 18px;color:#889;font-size:13px}
label{display:block;font-size:12px;color:#889;margin:12px 0 4px}
input{width:100%;box-sizing:border-box;padding:9px 11px;border:1px solid #cdd2da;border-radius:8px;background:transparent;color:inherit;font-size:14px}
button{width:100%;margin-top:18px;padding:10px;border:0;border-radius:8px;background:#3b6cf0;color:#fff;font-size:14px;font-weight:600;cursor:pointer}
.err{background:#fde8e8;color:#a11;border-radius:8px;padding:8px 11px;font-size:13px;margin:0 0 14px}
@media(prefers-color-scheme:dark){.err{background:#3a1e1e}}
</style></head><body>
<form method="post" action="/login">
<h1>OTA Console</h1><p class="s">Sign in to continue</p>
{error}
<input type="hidden" name="next" value="{next}">
<label>Username</label><input name="username" autocomplete="username" autofocus>
<label>Password</label><input name="password" type="password" autocomplete="current-password">
<button type="submit">Sign in</button>
</form></body></html>"""


def local_path(p):
    """Only allow same-origin redirect targets, never an absolute URL (open-redirect guard)."""
    return p if (p.startswith("/") and not p.startswith("//")) else "/"


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        print("auth: " + (fmt % args), flush=True)

    # ---- helpers ----
    def _send(self, code, body, ctype="application/json", extra=()):
        b = body.encode() if isinstance(body, str) else body
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(b)))
        for k, v in extra:
            self.send_header(k, v)
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(b)

    def _redirect(self, location, extra=()):
        self.send_response(302)
        self.send_header("Location", location)
        self.send_header("Content-Length", "0")
        for k, v in extra:
            self.send_header(k, v)
        self.end_headers()

    def _cookie(self):
        c = http.cookies.SimpleCookie(self.headers.get("Cookie", ""))
        return c[COOKIE].value if COOKIE in c else ""

    def _set_cookie(self, token, max_age=SESSION_TTL):
        parts = [f"{COOKIE}={token}", "Path=/", "HttpOnly", "SameSite=Lax", f"Max-Age={max_age}"]
        if COOKIE_SECURE:
            parts.append("Secure")
        return ("Set-Cookie", "; ".join(parts))

    def _body(self):
        n = int(self.headers.get("Content-Length", "0") or 0)
        return self.rfile.read(n) if n else b""

    def _json(self):
        try:
            return json.loads(self._body() or b"{}")
        except ValueError:
            return {}

    def _require_session(self):
        user = session_user(self._cookie())
        if not user:
            self._send(401, json.dumps({"error": "not authenticated"}))
            return None
        return user

    # ---- routing ----
    def do_GET(self):
        path = self.path.split("?")[0]
        if path == "/auth/verify":
            return self._verify()
        if path == "/login":
            return self._login_form()
        if path == "/auth/api/me":
            user = self._require_session()
            if user:
                self._send(200, json.dumps({"username": user}))
            return
        if path == "/auth/api/users":
            if self._require_session():
                self._send(200, json.dumps({"values": list_users()}))
            return
        if path in ("/auth/health", "/health"):
            return self._send(200, json.dumps({"ok": True}))
        self._send(404, json.dumps({"error": "not found"}))

    def do_POST(self):
        path = self.path.split("?")[0]
        if path == "/login":
            return self._login_submit()
        if path == "/logout":
            drop_session(self._cookie())
            return self._redirect("/login", [self._set_cookie("", max_age=0)])
        if path == "/auth/api/users":
            return self._create_user()
        m = re.match(r"^/auth/api/users/([^/]+)/password$", path)
        if m:
            return self._reset_password(urllib.parse.unquote(m.group(1)))
        self._send(404, json.dumps({"error": "not found"}))

    def do_DELETE(self):
        m = re.match(r"^/auth/api/users/([^/]+)$", self.path.split("?")[0])
        if m:
            return self._delete_user(urllib.parse.unquote(m.group(1)))
        self._send(404, json.dumps({"error": "not found"}))

    # ---- forward_auth ----
    def _verify(self):
        if session_user(self._cookie()):
            return self._send(200, "")
        # Caddy passes the original request via X-Forwarded-*. Bounce browsers to the login page
        # (carrying where they wanted to go); answer XHR/API callers with a plain 401.
        orig = self.headers.get("X-Forwarded-Uri", "/")
        accept = self.headers.get("Accept", "")
        if "text/html" in accept and not orig.startswith("/api") and not orig.startswith("/auth"):
            return self._redirect("/login?next=" + urllib.parse.quote(local_path(orig)))
        self._send(401, json.dumps({"error": "not authenticated"}))

    # ---- login ----
    def _login_form(self, error=""):
        if session_user(self._cookie()):
            return self._redirect("/")
        qs = urllib.parse.parse_qs(self.path.partition("?")[2])
        nxt = local_path((qs.get("next") or ["/"])[0])
        err = f'<div class="err">{error}</div>' if error else ""
        page = LOGIN_PAGE.replace("{error}", err).replace("{next}", nxt.replace('"', "%22"))
        self._send(200, page, "text/html; charset=utf-8")

    def _login_submit(self):
        form = urllib.parse.parse_qs(self._body().decode("utf-8", "replace"))
        username = (form.get("username") or [""])[0].strip()
        password = (form.get("password") or [""])[0]
        nxt = local_path((form.get("next") or ["/"])[0])
        if username and throttled(username):
            return self._login_form("Too many attempts. Wait a minute and try again.")
        if username and password and verify_pw(username, password):
            clear_fails(username)
            token = new_session(username)
            print(f"auth: login ok for '{username}'", flush=True)
            return self._redirect(nxt, [self._set_cookie(token)])
        record_fail(username)
        print(f"auth: login failed for '{username or '(blank)'}'", flush=True)
        self._login_form("Wrong username or password.")

    # ---- user admin (all require a session) ----
    def _create_user(self):
        if not self._require_session():
            return
        body = self._json()
        username = (body.get("username") or "").strip()
        password = body.get("password") or ""
        if not SAFE_USER.match(username):
            return self._send(400, json.dumps({"error": "username: letters, digits, . _ - (max 64)"}))
        if len(password) < 8:
            return self._send(400, json.dumps({"error": "password must be at least 8 characters"}))
        exists = any(u["username"] == username for u in list_users())
        set_user(username, password)
        print(f"auth: {'updated' if exists else 'created'} user '{username}'", flush=True)
        self._send(200, json.dumps({"username": username, "created": not exists}))

    def _reset_password(self, username):
        if not self._require_session():
            return
        password = self._json().get("password") or ""
        if not any(u["username"] == username for u in list_users()):
            return self._send(404, json.dumps({"error": "no such user"}))
        if len(password) < 8:
            return self._send(400, json.dumps({"error": "password must be at least 8 characters"}))
        set_user(username, password)                 # also purges that user's sessions
        print(f"auth: reset password for '{username}'", flush=True)
        self._send(200, json.dumps({"ok": True}))

    def _delete_user(self, username):
        me = self._require_session()
        if not me:
            return
        if not any(u["username"] == username for u in list_users()):
            return self._send(404, json.dumps({"error": "no such user"}))
        # Never let the console lock everyone out.
        if user_count() <= 1:
            return self._send(400, json.dumps({"error": "cannot delete the last user"}))
        delete_user(username)
        print(f"auth: deleted user '{username}'", flush=True)
        self._send(200, json.dumps({"ok": True}))


if __name__ == "__main__":
    ensure_admin()
    print(f"auth: listening on :{PORT} (cookie secure={COOKIE_SECURE}, session {SESSION_TTL}s)", flush=True)
    http.server.ThreadingHTTPServer(("0.0.0.0", PORT), Handler).serve_forever()
