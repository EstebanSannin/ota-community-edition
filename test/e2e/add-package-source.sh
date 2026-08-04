#!/usr/bin/env bash
set -uo pipefail
REPO="http://reposerver.ota.ce/api/v1/user_repo"
NS="x-ats-namespace:default"
SRC=/tmp/addsrc.json
NAME=$(jq -r '.delegationMetadata.name' "$SRC")
FRIENDLY="Common Torizon Nightly"
echo "delegation name: $NAME"

echo ""; echo "=== 1) PUT trusted-delegations/keys (the two RSA public keys) ==="
jq -c '.keys' "$SRC" | curl -sS -X PUT "$REPO/trusted-delegations/keys" \
  -H "$NS" -H "Content-Type: application/json" -d @- -w "\n  -> %{http_code}\n"

echo ""; echo "=== 2) PUT trusted-delegations (the role: keyids, paths, threshold) ==="
jq -c '[.delegationMetadata]' "$SRC" | curl -sS -X PUT "$REPO/trusted-delegations" \
  -H "$NS" -H "Content-Type: application/json" -d @- -w "\n  -> %{http_code}\n"

echo ""; echo "=== 3) PUT trusted-delegations/$NAME/remote (fetch + verify signature vs keys) ==="
BODY=$(jq -n --arg uri "$(jq -r '.fetchUrl.uri' "$SRC")" --arg fn "$FRIENDLY" '{uri:$uri, friendlyName:$fn}')
curl -sS -X PUT "$REPO/trusted-delegations/$NAME/remote" \
  -H "$NS" -H "Content-Type: application/json" -d "$BODY" -w "\n  -> %{http_code}\n"

echo ""; echo "=== 4) verify ==="
echo "--- trusted-delegations block (keys + roles registered) ---"
curl -sS "$REPO/trusted-delegations" -H "$NS" | jq '{keyids: (.keys|keys), roles: [.roles[]|{name,paths,threshold}]}' 2>/dev/null || curl -sS "$REPO/trusted-delegations" -H "$NS"
echo "--- delegation info (lastFetched proves remote pull worked) ---"
curl -sS "$REPO/trusted-delegations/$NAME/info" -H "$NS" -w "\n  -> %{http_code}\n"
