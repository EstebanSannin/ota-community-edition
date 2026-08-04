#!/usr/bin/env bash
# Mint + register one device, emit its credential bundle as JSON on stdout.
# Mirrors scripts/gen-device.sh but self-contained for the provisioner service.
set -euo pipefail

NAME="${1:-}"
GEN=/gen                       # mounted ota-ce-gen (ro): devices/ca.key, devices/ca.crt, server_ca.pem
CERTS=/certs                   # mounted scripts/certs (ro): client.cnf, client.ext
GW_URL="${GATEWAY_URL:-https://ota.ce:30443}"
DR_URL="${DEVICE_REGISTRY_URL:-http://ota-lith:7300/device-registry/api/v1/devices}"
NS="${NAMESPACE:-default}"

uuid=$(cat /proc/sys/kernel/random/uuid)
[ -z "$NAME" ] && NAME="$uuid"

tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
openssl ecparam -genkey -name prime256v1 2>/dev/null | openssl ec -out "$tmp/pkey.ec.pem" 2>/dev/null
openssl pkcs8 -topk8 -nocrypt -in "$tmp/pkey.ec.pem" -out "$tmp/pkey.pem" 2>/dev/null
openssl req -new -key "$tmp/pkey.pem" \
  -config <(sed "s/\$ENV::DEVICE_UUID/$uuid/g" "$CERTS/client.cnf") -out "$tmp/dev.csr" 2>/dev/null
# -set_serial (random) instead of -CAcreateserial so the CA dir can stay read-only
openssl x509 -req -days 365 -extfile "$CERTS/client.ext" -in "$tmp/dev.csr" \
  -CAkey "$GEN/devices/ca.key" -CA "$GEN/devices/ca.crt" \
  -set_serial "0x$(openssl rand -hex 16)" -out "$tmp/client.pem" 2>/dev/null

# register in the device-registry (merged into the director)
creds=$(sed -z -r 's/\n/\\n/g' "$tmp/client.pem")
body="{\"credentials\":\"${creds}\",\"deviceId\":\"${NAME}\",\"deviceName\":\"${NAME}\",\"deviceType\":\"Other\",\"uuid\":\"${uuid}\"}"
curl -sS -f -X POST "$DR_URL" -H "Content-Type: application/json" -H "x-ats-namespace: $NS" -d "$body" >/dev/null

jq -n --arg uuid "$uuid" --arg name "$NAME" --arg gw "$GW_URL" \
  --rawfile client "$tmp/client.pem" --rawfile pkey "$tmp/pkey.pem" --rawfile cacert "$GEN/server_ca.pem" \
  '{uuid:$uuid, name:$name, gatewayUrl:$gw, client:$client, pkey:$pkey, cacert:$cacert}'
