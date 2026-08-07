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

pass=0; fail=0
ok()   { printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$((pass+1)); }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail+1)); }
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

note "cleanup"
curl -s -o /dev/null -X DELETE "$R/targets/$TARGET"        && ok "deleted test target"  || bad "could not delete test target"
curl -s -o /dev/null -X DELETE "$D/offline-updates/$LOCKBOX" && ok "deleted test lockbox" || bad "could not delete test lockbox"

echo
if [ "$fail" -eq 0 ]; then
  printf '\033[32mSUMMARY: %d passed, 0 failed\033[0m\n' "$pass"; exit 0
else
  printf '\033[31mSUMMARY: %d passed, %d FAILED\033[0m\n' "$pass" "$fail"; exit 1
fi
