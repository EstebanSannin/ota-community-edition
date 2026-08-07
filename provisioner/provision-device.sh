#!/usr/bin/env bash
# Torizon-style one-liner provisioning for OTA Community Edition.
# Usage (on the device, as root):
#   curl -fsSL http://<server>:8080/provision-device.sh | sudo bash -s -- -s http://<server>:8080 [-n name]
set -euo pipefail

SERVER_URL=""; NAME=""; TOKEN=""; REPORTER=0; REMOTE=0
usage(){ echo "usage: curl -fsSL <server>/provision-device.sh | sudo bash -s -- -s <server-url> [-n name] [-t token] [-r] [-a]"; }
while getopts ":s:n:t:rah" o; do case $o in
  s) SERVER_URL=$OPTARG;; n) NAME=$OPTARG;; t) TOKEN=$OPTARG;; r) REPORTER=1;; a) REMOTE=1;; h) usage; exit 0;; \?) usage; exit 1;; esac; done

[ -z "$SERVER_URL" ] && { echo "ERROR: -s <server-url> is required"; usage; exit 1; }
[ "$(id -u)" -ne 0 ] && { echo "ERROR: run as root (pipe into 'sudo bash')"; exit 1; }
for d in curl jq; do command -v "$d" >/dev/null || { echo "ERROR: missing dependency: $d"; exit 1; }; done

echo "== Requesting device credentials from $SERVER_URL ..."
AUTH=(); [ -n "$TOKEN" ] && AUTH=(-H "Authorization: Bearer $TOKEN")
resp=$(curl -fsSL -X POST "$SERVER_URL/api/provision" -H 'Content-Type: application/json' "${AUTH[@]}" \
        -d "{\"name\":\"${NAME}\"}") || { echo "ERROR: provisioning request failed (if the server requires a token, pass -t <token>)"; exit 1; }

uuid=$(echo "$resp"  | jq -r .uuid)
gwurl=$(echo "$resp" | jq -r .gatewayUrl)
gwhost=$(echo "$gwurl"     | sed -E 's#^https?://##; s#[:/].*$##')   # e.g. ota.ce  (the TLS cert CN)
srvhost=$(echo "$SERVER_URL" | sed -E 's#^https?://##; s#[:/].*$##') # e.g. 192.168.1.215
[ -z "$uuid" ] && { echo "ERROR: server response invalid"; echo "$resp"; exit 1; }
echo "== Device UUID: $uuid   gateway: $gwurl   (via $srvhost)"

echo "== Writing credentials to /var/sota/import ..."
mkdir -p /var/sota/import
echo "$resp" | jq -r .client > /var/sota/import/client.pem
echo "$resp" | jq -r .pkey   > /var/sota/import/pkey.pem
echo "$resp" | jq -r .cacert > /var/sota/import/root.crt
echo "$gwurl" > /var/sota/import/gateway.url
chmod 600 /var/sota/import/pkey.pem

# Map the gateway hostname only if it does NOT resolve (e.g. the ota.ce placeholder) AND we reached
# the server by IP. With a real DNS gateway (recommended) this is skipped entirely.
if ! getent hosts "$gwhost" >/dev/null 2>&1 && echo "$srvhost" | grep -qE '^[0-9.]+$'; then
  grep -qE "[[:space:]]$gwhost(\$|[[:space:]])" /etc/hosts || { echo "$srvhost $gwhost" >> /etc/hosts; echo "== Mapped $gwhost -> $srvhost in /etc/hosts"; }
fi

# override the baked-in gateway URL + server CA (which point at Torizon Cloud)
mkdir -p /etc/sota/conf.d
cat > /etc/sota/conf.d/90-ce.toml <<EOF
[tls]
server_url_path = "/var/sota/import/gateway.url"

[import]
tls_cacert_path = "/var/sota/import/root.crt"
EOF

rm -f /var/sota/sql.db
# Secondaries keep their OWN TUF store, and it is NOT covered by /var/sota/sql.db. A board that
# was previously registered elsewhere (e.g. Torizon Cloud) keeps that instance's root chain — at a
# higher version and with different keys — so it rejects this server's metadata with
# "A key has an incorrect associated key ID" and every app update fails. Drop the stored metadata
# (keeping each Secondary's keys/serial) so they re-learn the root from this server.
for secdb in /var/sota/storage/*/sql.db; do
  [ -f "$secdb" ] || continue
  python3 - "$secdb" <<'PY' || echo "WARN: could not reset $(dirname "$secdb")"
import sqlite3, sys
db = sys.argv[1]
con = sqlite3.connect(db)
if con.execute("select count(*) from sqlite_master where type='table' and name='meta'").fetchone()[0]:
    n = con.execute("select count(*) from meta").fetchone()[0]
    con.execute("delete from meta")
    con.commit()
    print(f"== Reset stale TUF metadata in {db} ({n} row(s))")
PY
done

echo "== Starting aktualizr ..."
systemctl restart aktualizr

if [ "$REPORTER" = "1" ]; then
  echo "== Installing the hardware reporter ..."
  curl -fsSL "$SERVER_URL/install-reporter.sh" | bash || echo "WARN: reporter install failed (device is still provisioned)"
fi

if [ "$REMOTE" = "1" ]; then
  if command -v rac >/dev/null 2>&1; then
    echo "== Enabling remote access (rac) ..."
    RACDIR=/home/torizon/run/rac
    mkdir -p /etc/rac "$RACDIR/uptane" /home/torizon/.ssh
    rm -rf "$RACDIR/uptane"/*   # drop any stale TUF cache so rac re-pins this instance's root
    chown -R torizon:torizon /home/torizon/run /home/torizon/.ssh 2>/dev/null || true
    chmod 700 /home/torizon/.ssh 2>/dev/null || true
    cat > /etc/rac/client.toml <<RAC
[torizon]
url = "${gwurl}/ras/"
director_url = "${gwurl}/ras/director/"
server_cert_path = "/var/sota/import/root.crt"
client_cert_path = "/var/sota/import/client.pem"
client_key_path = "/var/sota/import/pkey.pem"

[device]
ssh_private_key_path = "$RACDIR/device-key.sec"
local_tuf_repo_path = "$RACDIR/uptane"
unprivileged_user_group = "torizon:torizon"
poll_timeout = { secs = 3, nanos = 0 }

[device.session.target_host]
host_port = "127.0.0.1:22"
authorized_keys_path = "/home/torizon/.ssh/authorized_keys"
RAC
    cat > /etc/systemd/system/rac.service <<'SVC'
[Unit]
Description=Torizon Remote Access Client (OTA CE)
After=network-online.target
Wants=network-online.target

[Service]
Environment=CONFIG_FILE=/etc/rac/client.toml
ExecStart=/usr/bin/rac
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
SVC
    systemctl daemon-reload
    systemctl enable --now rac.service && echo "== Remote access enabled (persistent rac.service)"
  else
    echo "WARN: 'rac' not found — skipping remote access (it ships with Torizon OS)"
  fi
fi

echo ""
echo "== Success! Device $uuid provisioned against $gwurl"
echo "   Follow logs with:  journalctl -f -u aktualizr-torizon"
