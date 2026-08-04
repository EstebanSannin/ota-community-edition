#!/usr/bin/env bash
set -euo pipefail
cd ~/ota-community-edition
NS="x-ats-namespace:default"
HW="ota-ce-device"
NAME="mypkg"; VER="${VER:-0.0.1}"; TARGET="${NAME}-${VER}"
UUID=$(ls -t ota-ce-gen/devices/ | grep -E '^[0-9a-f-]{36}$' | head -1)
echo "device=$UUID hardware=$HW target=$TARGET"

BIN=/tmp/${TARGET}.bin
head -c 4096 /dev/urandom > "$BIN"
HASH=$(sha256sum "$BIN" | awk '{print $1}')
LEN=$(stat -c %s "$BIN")
echo "hash=$HASH len=$LEN"

echo "--- 1) push target to reposerver (server signs) ---"
curl -sS -f -X PUT \
  "http://reposerver.ota.ce/api/v1/user_repo/targets/${TARGET}?name=${NAME}&version=${VER}&hardwareIds=${HW}" \
  -H "$NS" -F "file=@${BIN}" -o /dev/null -w "  push -> %{http_code}\n"

echo "--- 2) create multi-target update ---"
MTU_BODY="{\"targets\":{\"${HW}\":{\"to\":{\"target\":\"${TARGET}\",\"checksum\":{\"method\":\"sha256\",\"hash\":\"${HASH}\"},\"targetLength\":${LEN}},\"targetFormat\":\"BINARY\",\"generateDiff\":false}}}"
MTU_RAW=$(curl -sS -f -X POST "http://director.ota.ce/api/v1/multi_target_updates" \
  -H "$NS" -H "Content-Type: application/json" -d "$MTU_BODY")
MTU=$(echo "$MTU_RAW" | tr -d '"')
echo "  mtuId=$MTU"

echo "--- 3) assign to device ---"
CORR="urn:here-ota:mtu:${MTU}"
curl -sS -f -X POST "http://director.ota.ce/api/v1/assignments" \
  -H "$NS" -H "Content-Type: application/json" \
  -d "{\"correlationId\":\"${CORR}\",\"mtuId\":\"${MTU}\",\"devices\":[\"${UUID}\"]}" \
  -w "\n  assign -> %{http_code}\n"
echo "done. correlationId=$CORR"
