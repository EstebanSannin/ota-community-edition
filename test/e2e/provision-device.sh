#!/usr/bin/env bash
set -uo pipefail
cd ~/ota-community-edition
UUID=$(ls -t ota-ce-gen/devices/ | grep -E '^[0-9a-f-]{36}$' | head -1)
echo "waiting for aktualizr:local image..."
for i in $(seq 1 30); do docker image inspect aktualizr:local >/dev/null 2>&1 && { echo "image ready"; break; }; sleep 4; done
docker image inspect aktualizr:local >/dev/null 2>&1 || { echo "IMAGE NOT READY"; exit 1; }
docker run --rm aktualizr:local --version 2>&1 | head -1

echo ""
echo "device=$UUID"
echo "=== aktualizr provision (run-mode=once) ==="
docker run --rm --add-host ota.ce:host-gateway \
  -v "$PWD/ota-ce-gen/devices/$UUID:/device" \
  aktualizr:local --run-mode=once --config=/device/config.toml > /tmp/akt1.log 2>&1
echo "exit=$?"
echo "--- key lines ---"
grep -iE "provision|ecu|registered|current versions|no update|no new|error|could|ssl|handshake|refused|fault|reject|report|manifest|success" /tmp/akt1.log | tail -40

echo ""
echo "=== device state in director now (lastSeen / status) ==="
curl -s -H "x-ats-namespace: default" "http://director.ota.ce/device-registry/api/v1/devices" | head -c 700
echo
echo "=== director knows the ECUs? ==="
curl -s -H "x-ats-namespace: default" "http://director.ota.ce/api/v1/admin/devices/$UUID/ecus" -w "\n-> %{http_code}\n" | head -c 400
