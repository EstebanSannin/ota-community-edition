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
import http.server, io, json, os, re, urllib.error, urllib.parse, urllib.request, zipfile

DIRECTOR = os.environ.get("DIRECTOR_URL", "http://ota-lith:7300/api/v1")
REPOSERVER = os.environ.get("REPOSERVER_URL", "http://ota-lith:7100/api/v1")
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


def build_zip(name):
    targets, _ = lockbox_targets(name)
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w", zipfile.ZIP_DEFLATED) as z:
        d = f"{BUNDLE_DIR}/metadata/director"
        z.writestr(f"{d}/root.json", fetch(f"{DIRECTOR}/admin/repo/root.json"))
        z.writestr(f"{d}/offline-snapshot.json", fetch(f"{DIRECTOR}/admin/repo/offline-snapshot.json"))
        z.writestr(f"{d}/{name}.json", fetch(f"{DIRECTOR}/admin/repo/offline-updates/{name}.json"))
        for role in IMAGE_REPO_ROLES:
            z.writestr(f"{BUNDLE_DIR}/metadata/image-repo/{role}",
                       fetch(f"{REPOSERVER}/user_repo/{role}"))
        for filename in targets:
            safe = filename.replace("..", "_").lstrip("/")
            z.writestr(f"{BUNDLE_DIR}/images/{safe}",
                       fetch(f"{REPOSERVER}/user_repo/targets/{urllib.parse.quote(filename)}"))
        z.writestr(f"{BUNDLE_DIR}/README.txt", README)
    return buf.getvalue()


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


if __name__ == "__main__":
    print(f"lockbox: listening on :{PORT}, director={DIRECTOR}, reposerver={REPOSERVER}", flush=True)
    http.server.ThreadingHTTPServer(("0.0.0.0", PORT), Handler).serve_forever()
