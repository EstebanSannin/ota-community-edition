#!/usr/bin/env bash
# One-command bring-up for OTA Community Edition.
# Builds the ota-lith image (if missing), generates certs, starts the stack, and
# initializes the TUF repository. Idempotent — safe to re-run.
set -euo pipefail
cd "$(dirname "$0")"

# Release mode: if OTA_CE_NS is set, pull prebuilt images (compose.release.yaml) — no sbt needed.
# Otherwise, build the ota-lith image locally from source (needs JDK 21 + sbt).
IMG=uptane/ota-lith:latest
PROJECT=ota-community-edition
if [ -n "${OTA_CE_NS:-}" ]; then
  COMPOSE=(docker compose -f compose.release.yaml)
  RELEASE=1
else
  COMPOSE=(docker compose -f ota-ce.yaml)
  RELEASE=
fi

say(){ printf '\n\033[1;36m== %s\033[0m\n' "$*"; }

say "1/6  Checking prerequisites"
command -v docker >/dev/null || { echo "Docker is required."; exit 1; }
docker compose version >/dev/null 2>&1 || { echo "The 'docker compose' plugin is required."; exit 1; }
echo "   docker ok"

if [ -n "$RELEASE" ]; then
  say "2/6  Pulling prebuilt images ($OTA_CE_NS, tag ${OTA_CE_TAG:-latest})"
  "${COMPOSE[@]}" pull
else
  say "2/6  Building the ota-lith image (if missing)"
  if docker image inspect "$IMG" >/dev/null 2>&1; then
    echo "   $IMG already present."
  elif command -v sbt >/dev/null 2>&1; then
    echo "   building with sbt — the first build takes several minutes…"
    sbt "Docker / publishLocal"
  else
    echo "   ERROR: image '$IMG' not found and 'sbt' is not installed."
    echo "   Either set OTA_CE_NS to pull prebuilt images, or install JDK 21 + sbt and run:"
    echo "     sbt \"Docker / publishLocal\"   — then re-run ./bootstrap.sh"
    exit 1
  fi
fi

say "3/6  Generating server + device CA certificates (if missing)"
if [ -d ota-ce-gen ]; then echo "   ota-ce-gen/ already exists — keeping it."; else scripts/gen-server-certs.sh; fi

say "4/6  Starting the stack"
"${COMPOSE[@]}" up -d

say "5/6  Waiting for ota-lith to become healthy"
status=starting
for _ in $(seq 1 80); do
  status=$(docker inspect -f '{{.State.Health.Status}}' "${PROJECT}-ota-lith-1" 2>/dev/null || echo starting)
  [ "$status" = healthy ] && break
  sleep 3
done
if [ "$status" != healthy ]; then
  echo "   ota-lith did not become healthy in time. Recent logs:"
  "${COMPOSE[@]}" logs --tail 40 ota-lith
  exit 1
fi
echo "   healthy."

say "6/6  Initializing the TUF repository"
# Go through the console proxy on :8080, which is published in BOTH dev and release modes. (The
# reverse-proxy's port 80 is only published by ota-ce.yaml; compose.release.yaml keeps it internal,
# so the old localhost:80 path silently failed to initialise TUF on a release bring-up.)
curl -sS -X POST http://localhost:8080/api/reposerver/user_repo      >/dev/null 2>&1 || true
curl -sS -X POST http://localhost:8080/api/director/admin/repo       >/dev/null 2>&1 || true
code=$(curl -sS -o /dev/null -w '%{http_code}' http://localhost:8080/api/reposerver/user_repo/root.json)
echo "   user_repo/root.json -> $code"

cat <<EOF

  ✔ OTA Community Edition is up.

    Console      http://localhost:8080
    Provision    open the console → "Provision device"  (one-liner, runs on the device)
    Stop         ${COMPOSE[*]} down       (add -v to also wipe the database)

  See docs/status-report.md for what works and how the pieces fit together.
EOF
