#!/usr/bin/env bash
# Torizon-style one-liner provisioning for OTA Community Edition.
# Usage (on the device, as root):
#   curl -fsSL http://<server>:8080/provision-device.sh | sudo bash -s -- -s http://<server>:8080 [-n name]
set -euo pipefail

SERVER_URL=""; NAME=""; TOKEN=""
usage(){ echo "usage: curl -fsSL <server>/provision-device.sh | sudo bash -s -- -s <server-url> [-n name] [-t token]"; }
while getopts ":s:n:t:h" o; do case $o in
  s) SERVER_URL=$OPTARG;; n) NAME=$OPTARG;; t) TOKEN=$OPTARG;; h) usage; exit 0;; \?) usage; exit 1;; esac; done

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

# resolve the gateway hostname (cert CN) to the server host
if ! grep -qE "[[:space:]]$gwhost(\$|[[:space:]])" /etc/hosts; then
  echo "$srvhost $gwhost" >> /etc/hosts
  echo "== Added '$srvhost $gwhost' to /etc/hosts"
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
echo "== Starting aktualizr ..."
systemctl restart aktualizr

echo ""
echo "== Success! Device $uuid provisioned against $gwurl"
echo "   Follow logs with:  journalctl -f -u aktualizr-torizon"
