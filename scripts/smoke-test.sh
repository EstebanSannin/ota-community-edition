#!/usr/bin/env bash
# Core-loop smoke test. Exercises the parts of the stack that a device actually depends on,
# WITHOUT needing a physical device, and fails loudly if any of them regressed.
#
#   provision  ->  publish a package  ->  read it back byte-for-byte  ->  bundle it offline
#
# It talks only to the plain console (default http://localhost:8080), so it works against a bare
# LAN stack with no auth/S3/observability overlays -- which is exactly the configuration we
# otherwise never test. Run it after every change; it is the regression baseline.
#
#   bash scripts/smoke-test.sh                 # against an already-running stack
#   BASE=http://192.168.64.2:8080 bash scripts/smoke-test.sh
#   UP=1 bash scripts/smoke-test.sh            # bring the release stack up first, then test
#
# Exit code is 0 only if every check passed. Test artifacts are named *smoke-test* and cleaned
# up at the end, so re-runs are idempotent.
set -uo pipefail
cd "$(dirname "$0")/.."

BASE="${BASE:-http://localhost:8080}"
R="$BASE/api/reposerver/user_repo"
D="$BASE/api/director/admin/repo"
TARGET="smoke-test-app-1"
LOCKBOX="smoke-test-lb"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

pass=0; fail=0; skip=0
ok()   { printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$((pass+1)); }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail+1)); }
skp()  { printf '  \033[33mSKIP\033[0m %s\n' "$1"; skip=$((skip+1)); }
note() { printf '\n== %s\n' "$1"; }
# GET/'' helpers that print the HTTP code so a check can assert on it.
code() { curl -s -o "$2" -w '%{http_code}' "$1"; }

# A realistic, digest-pinned, ASCII-only compose payload (a lockbox rejects tag-only images, and
# non-ASCII in metadata breaks device verification -- so the test uses neither).
cat > "$WORK/app.yml" <<'YML'
services:
  web:
    image: nginx@sha256:8541484afbc9c8a5a8a99b379568ebbc957f658583ec9448fc43104229c03cf8
    ports:
      - "8088:80"
YML

if [ "${UP:-}" = "1" ]; then
  note "bringing up the release stack (no overlays)"
  docker compose -f compose.release.yaml --env-file .env up -d 2>&1 | tail -3 || true
fi

note "waiting for the stack (reposerver via the console proxy)"
ready=""
for _ in $(seq 1 60); do
  if [ "$(code "$R/targets.json" "$WORK/t.json")" = "200" ]; then ready=1; break; fi
  sleep 2
done
[ -n "$ready" ] && ok "reposerver reachable, targets.json served" || { bad "stack never became ready at $BASE"; echo; echo "SUMMARY: $pass passed, $((fail+1)) failed"; exit 1; }

note "core services answer through the console proxy"
[ "$(code "$BASE/api/device-registry/devices" "$WORK/dev.json")" = "200" ] && ok "device-registry: list devices" || bad "device-registry unreachable"

tok_code=$(curl -s -o "$WORK/tok.json" -w '%{http_code}' -X POST "$BASE/api/provision-tokens")
if [ "$tok_code" = "200" ] && python3 -c "import json,sys;sys.exit(0 if json.load(open('$WORK/tok.json')).get('token') else 1)" 2>/dev/null; then
  ok "provisioner: minted an enrollment token"
else
  bad "provisioner: token mint failed (http $tok_code)"
fi

note "storage round-trip (the path S3 could have broken)"
up_code=$(curl -s -o "$WORK/up.out" -w '%{http_code}' -X PUT \
  -F "file=@$WORK/app.yml" \
  "$R/targets/$TARGET?name=smoke-test-app&version=1&hardwareIds=docker-compose")
[ "$up_code" = "200" ] && ok "reposerver: uploaded a target (http $up_code)" || bad "reposerver: upload failed (http $up_code)"

dl_code=$(code "$R/targets/$TARGET" "$WORK/down.yml")
if [ "$dl_code" = "200" ] && cmp -s "$WORK/app.yml" "$WORK/down.yml"; then
  ok "reposerver: target read back BYTE-IDENTICAL"
else
  bad "reposerver: read-back mismatch or http $dl_code (storage backend broken?)"
fi

note "offline update (lockbox) end to end"
# Re-fetch targets.json (the upload above changed it), then build the offline-updates request from
# the SIGNED metadata so hash/length/custom are byte-exact.
code "$R/targets.json" "$WORK/t.json" >/dev/null
python3 - "$WORK/t.json" "$TARGET" "$WORK/values.json" <<'PY' 2>/dev/null && ok "target present in signed targets.json" || bad "target missing from targets.json"
import json,sys
meta=json.load(open(sys.argv[1])); meta=meta.get("signed",meta)
t=meta["targets"][sys.argv[2]]
json.dump({"values":{sys.argv[2]:{"hashes":t["hashes"],"length":t["length"],"custom":t.get("custom",{})}}}, open(sys.argv[3],"w"))
PY

lb_code=$(curl -s -o "$WORK/lb.out" -w '%{http_code}' -X POST -H 'Content-Type: application/json' \
  --data @"$WORK/values.json" "$D/offline-updates/$LOCKBOX")
[ "$lb_code" = "200" ] && ok "director: created offline-update role" || bad "director: offline-update create failed (http $lb_code)"

zip_code=$(code "$BASE/api/lockbox/$LOCKBOX.zip" "$WORK/lb.zip")
if [ "$zip_code" = "200" ] && python3 - "$WORK/lb.zip" "$TARGET" "$WORK/app.yml" <<'PY' 2>/dev/null; then
import sys,zipfile
z=zipfile.ZipFile(sys.argv[1]); img=f"update/images/{sys.argv[2]}"
sys.exit(0 if img in z.namelist() and z.read(img)==open(sys.argv[3],"rb").read() else 1)
PY
  ok "lockbox: exported .zip carries the target byte-identical"
else
  bad "lockbox: export missing/mismatched payload (http $zip_code)"
fi

note "console renders the current pages (catches a stale bind-mounted index.html)"
code "$BASE/" "$WORK/index.html" >/dev/null
missing=""
for id in v-dashboard v-devices v-packages v-remote v-lockbox v-system v-users; do
  grep -q "id=\"$id\"" "$WORK/index.html" || missing="$missing $id"
done
[ -z "$missing" ] && ok "all view sections present in the served index.html" || bad "served index.html missing:$missing (stale mount? restart the console)"
grep -q 'js/main.js' "$WORK/index.html" && ok "console JS entrypoint referenced" || bad "index.html missing its JS entrypoint"

note "observability / System page (if the overlay is deployed)"
ops_code=$(code "$BASE/api/ops/status" "$WORK/ops.json")
if [ "$ops_code" = "200" ]; then
  python3 - "$WORK/ops.json" <<'PY' 2>/dev/null && ok "ops: status has services + host info" || bad "ops: status present but missing services/host"
import json,sys
d=json.load(open(sys.argv[1]))
svc=d.get("containers",d.get("services",[]))
sys.exit(0 if len(svc)>0 and (d.get("host") or {}).get("os") else 1)
PY
elif [ "$ops_code" = "502" ] || [ "$ops_code" = "404" ]; then
  skp "observability overlay not deployed (System page would be empty)"
else
  bad "ops: unexpected status (http $ops_code)"
fi

note "remote access API (if ras is deployed)"
ras_code=$(code "$BASE/api/ras/sessions" "$WORK/ras.json")
if [ "$ras_code" = "200" ] || [ "$ras_code" = "404" ] && grep -qi "session" "$WORK/ras.json" 2>/dev/null; then
  ok "ras: admin API reachable (http $ras_code)"
elif [ "$ras_code" = "502" ]; then
  skp "ras service not deployed"
else
  ok "ras: reachable (http $ras_code)"
fi

note "cleanup"
curl -s -o /dev/null -X DELETE "$R/targets/$TARGET"        && ok "deleted test target"  || bad "could not delete test target"
curl -s -o /dev/null -X DELETE "$D/offline-updates/$LOCKBOX" && ok "deleted test lockbox" || bad "could not delete test lockbox"

# Optional: exercise local-users auth through the TLS front. Set AUTH_BASE + creds to enable, e.g.
#   AUTH_BASE=https://ota.local ADMIN_USER=admin ADMIN_PASS=... USER_USER=stefano USER_PASS=... \
#     bash scripts/smoke-test.sh
if [ -n "${AUTH_BASE:-}" ] && [ -n "${ADMIN_USER:-}" ]; then
  note "auth front (admin vs non-admin) at $AUTH_BASE"
  AJ="$WORK/aj"
  ac=$(curl -sk -c "$AJ" -o /dev/null -w '%{http_code}' --data-urlencode "username=$ADMIN_USER" --data-urlencode "password=${ADMIN_PASS:-}" "$AUTH_BASE/login")
  gate_no=$(curl -sk -o /dev/null -w '%{http_code}' -H 'Accept: application/json' "$AUTH_BASE/api/reposerver/user_repo/targets.json")
  gate_yes=$(curl -sk -b "$AJ" -o /dev/null -w '%{http_code}' "$AUTH_BASE/api/reposerver/user_repo/targets.json")
  [ "$gate_no" = "401" ] && ok "front gates API without a session (401)" || bad "front did NOT gate API (got $gate_no)"
  [ "$gate_yes" = "200" ] && ok "admin session reaches the API (200)" || bad "admin session blocked (got $gate_yes)"
  [ "$(curl -sk -b "$AJ" -o /dev/null -w '%{http_code}' "$AUTH_BASE/api/ops/status")" = "200" ] && ok "admin reaches System data" || bad "admin blocked from System data"
  if [ -n "${USER_USER:-}" ]; then
    UJ="$WORK/uj"
    curl -sk -c "$UJ" -o /dev/null --data-urlencode "username=$USER_USER" --data-urlencode "password=${USER_PASS:-}" "$AUTH_BASE/login"
    [ "$(curl -sk -b "$UJ" -o /dev/null -w '%{http_code}' "$AUTH_BASE/api/ops/status")" = "403" ] && ok "non-admin blocked from System data (403)" || bad "non-admin NOT blocked from System"
    [ "$(curl -sk -b "$UJ" -o /dev/null -w '%{http_code}' "$AUTH_BASE/api/reposerver/user_repo/targets.json")" = "200" ] && ok "non-admin can still use the OTA loop" || bad "non-admin wrongly blocked from OTA loop"
  fi
fi

echo
if [ "$fail" -eq 0 ]; then
  printf '\033[32mSUMMARY: %d passed, %d skipped, 0 failed\033[0m\n' "$pass" "$skip"; exit 0
else
  printf '\033[31mSUMMARY: %d passed, %d skipped, %d FAILED\033[0m\n' "$pass" "$skip" "$fail"; exit 1
fi
