#!/usr/bin/env bash
# Provision a fresh Debian VPS with the full OTA CE stack + remote access, behind a
# TLS + shared-password front (Caddy). Idempotent — safe to re-run. Run as root:
#
#   OTA_CE_NS=samnite \
#   RAS_PUBLIC_HOST=ota.example.com \
#   ACME_EMAIL=you@example.com \
#   CONSOLE_PASSWORD_HASH='$2a$14$...'   # from: docker run --rm caddy caddy hash-password -p PASS
#   bash provision-vps.sh
#
# Leave CONSOLE_PASSWORD_HASH empty to bring up everything EXCEPT the public Caddy front
# (the console then stays on 127.0.0.1 only). Re-run later with the hash to add the front.
set -euo pipefail

OTA_CE_NS="${OTA_CE_NS:?set OTA_CE_NS (your Docker Hub namespace, e.g. samnite)}"
OTA_CE_TAG="${OTA_CE_TAG:-latest}"
REPO_URL="${REPO_URL:-https://github.com/EstebanSannin/ota-community-edition.git}"
REPO_BRANCH="${REPO_BRANCH:-greenfield-boot-fixes}"
APP_DIR="${APP_DIR:-/opt/ota-community-edition}"
RAS_PUBLIC_HOST="${RAS_PUBLIC_HOST:?set RAS_PUBLIC_HOST (public hostname for console + bastion)}"
ACME_EMAIL="${ACME_EMAIL:-}"
RAS_SSH_USER="${RAS_SSH_USER:-torizon}"
CONSOLE_USER="${CONSOLE_USER:-admin}"
CONSOLE_PASSWORD_HASH="${CONSOLE_PASSWORD_HASH:-}"
ADMIN_USER="${ADMIN_USER:-esteban}"
ADMIN_PUBKEY="${ADMIN_PUBKEY:-}"          # if empty, reuse the non-automation keys from root
PROJECT="$(basename "$APP_DIR")"
say(){ printf '\n\033[1;36m== %s\033[0m\n' "$*"; }

say "1/8  admin user: $ADMIN_USER"
id "$ADMIN_USER" &>/dev/null || adduser --disabled-password --gecos "" "$ADMIN_USER"
usermod -aG sudo "$ADMIN_USER"
echo "$ADMIN_USER ALL=(ALL) NOPASSWD:ALL" > "/etc/sudoers.d/90-$ADMIN_USER"
chmod 440 "/etc/sudoers.d/90-$ADMIN_USER"
install -d -m700 -o "$ADMIN_USER" -g "$ADMIN_USER" "/home/$ADMIN_USER/.ssh"
if [ -n "$ADMIN_PUBKEY" ]; then echo "$ADMIN_PUBKEY" > "/home/$ADMIN_USER/.ssh/authorized_keys"
else grep -v 'claude-ota-ce-vm' /root/.ssh/authorized_keys 2>/dev/null > "/home/$ADMIN_USER/.ssh/authorized_keys" || true; fi
chown "$ADMIN_USER:$ADMIN_USER" "/home/$ADMIN_USER/.ssh/authorized_keys"; chmod 600 "/home/$ADMIN_USER/.ssh/authorized_keys"

say "2/8  docker + deps"
if ! command -v docker >/dev/null 2>&1; then curl -fsSL https://get.docker.com | sh; fi
DEBIAN_FRONTEND=noninteractive apt-get install -y -q git ufw curl >/dev/null
usermod -aG docker "$ADMIN_USER"

say "3/8  firewall (ufw)"
ufw allow 22/tcp     >/dev/null
ufw allow 80,443/tcp >/dev/null   # console (Caddy: ACME + HTTPS)
ufw allow 30443/tcp  >/dev/null   # device mTLS gateway
ufw allow 2222/tcp   >/dev/null   # remote-access bastion control
ufw allow 22000:22003/tcp >/dev/null  # remote-access tunnels
ufw --force enable >/dev/null
ufw status | tail -n +1

say "4/8  repo -> $APP_DIR ($REPO_BRANCH)"
git config --global --add safe.directory "$APP_DIR"   # repo may be owned by $ADMIN_USER from a prior run
if [ -d "$APP_DIR/.git" ]; then
  git -C "$APP_DIR" fetch --depth 1 origin "$REPO_BRANCH"
  git -C "$APP_DIR" checkout -q "$REPO_BRANCH"
  git -C "$APP_DIR" reset --hard "origin/$REPO_BRANCH"
else
  git clone --depth 1 -b "$REPO_BRANCH" "$REPO_URL" "$APP_DIR"
fi
cd "$APP_DIR"

say "5/8  build local images (ras + provisioner)"
docker build -t "$OTA_CE_NS/ras:$OTA_CE_TAG" remote-access/ras
docker build -t "$OTA_CE_NS/ota-ce-provisioner:$OTA_CE_TAG" provisioner

say "6/8  .env + Caddyfile"
# Enrollment is gated by SHORT-LIVED tokens the operator mints from the console — no static shared
# secret. PROVISION_REQUIRE_TOKEN=1 makes the provisioner require a (minted) token to enroll.
cat > "$APP_DIR/.env" <<EOF
OTA_CE_NS=$OTA_CE_NS
OTA_CE_TAG=$OTA_CE_TAG
RAS_PUBLIC_HOST=$RAS_PUBLIC_HOST
RAS_SSH_USER=$RAS_SSH_USER
CONSOLE_BIND=127.0.0.1
GATEWAY_URL=https://$RAS_PUBLIC_HOST:30443
PROVISION_REQUIRE_TOKEN=1
PROVISION_TOKEN_TTL=3600
EOF
# Console login via GitHub (optional). Written here so compose can interpolate them; the secret
# itself comes from the environment of whoever runs this script — it is never echoed.
if [ -n "${GITHUB_CLIENT_ID:-}" ]; then
  cat >> "$APP_DIR/.env" <<EOF
GITHUB_CLIENT_ID=$GITHUB_CLIENT_ID
GITHUB_CLIENT_SECRET=$GITHUB_CLIENT_SECRET
OAUTH_ALLOWED_USERS=$OAUTH_ALLOWED_USERS
EOF
fi
# Render the Caddyfile with values inlined (incl. the bcrypt hash) — no env-var indirection, so
# compose's interpolation can't mangle the hash's '$' chars.
# caddy/Caddyfile is gitignored (generated secret); the checked-in template is caddy/Caddyfile.example.
#
# Two login modes. GITHUB_CLIENT_ID set -> per-user GitHub login via oauth2-proxy; otherwise the
# single shared password (basic_auth). Either way the device-enrollment paths bypass the login
# entirely — they are gated by a short-lived provisioning token instead, and keeping them in Caddy
# means enrollment keeps working even if oauth2-proxy is down.
render_caddyfile() {
  mkdir -p "$APP_DIR/caddy"
  {
    # LOCAL_TLS=1 makes Caddy issue its own certificate from a built-in CA (`tls internal`) instead
    # of Let's Encrypt -- for a LAN / air-gapped instance with no public DNS and no internet. Trust
    # Caddy's root once (it prints where) or use --cacert / -k when testing.
    if [ "${LOCAL_TLS:-}" != "1" ]; then
      printf '{\n\temail %s\n}\n\n' "$ACME_EMAIL"
    fi
    printf '%s {\n' "$RAS_PUBLIC_HOST"
    [ "${LOCAL_TLS:-}" = "1" ] && printf '\ttls internal\n'
    printf '\t@provision path /provision-device.sh /install-reporter.sh /api/provision /api/provision/*\n'
    printf '\thandle @provision {\n\t\treverse_proxy console:80\n\t}\n'
    # Tooling (torizoncore-builder / garage-sign) authenticates with a bearer token from
    # /tuf/oauth2/token, not a browser session, so this path skips the console login.
    # NOTE: deliberately NO `encode` here. TUF pins the sha256 AND length of each metadata file,
    # so a compressed response can never verify — the same trap that broke every device update
    # until the gateway stopped gzipping (see ota-ce/gateway.conf).
    # Tooling (torizoncore-builder / garage-sign): the image repo lives under /tuf and the director
    # offline-update roles under /director (TCB derives that path from tufrepo.url). Both are
    # bearer-authenticated by the lockbox service, so they bypass the browser login. No `encode`:
    # TUF pins each file's length+hash, so a compressed response can never verify.
    printf '\t@tooling path /tuf /tuf/* /director /director/* /treehub /treehub/*\n'
    printf '\thandle @tooling {\n\t\treverse_proxy lockbox:9920\n\t}\n'
    if [ -n "${MINIO_ROOT_PASSWORD:-}" ]; then
      # Pre-signed S3 URLs address the bucket by path, so they arrive here as
      # /<bucket>/<key>?X-Amz-... Pass them to MinIO byte-for-byte: the path is part of what the
      # signature covers, and MinIO verifies the signature itself (an unsigned request gets a 403),
      # so this must not be rewritten, compressed, or put behind the console login.
      printf '\t@s3 path /%s/*\n' "${TUF_TARGETS_BUCKET:-ota-targets}"
      # header_up -Authorization is REQUIRED, not tidying. garage-sign (inside
      # torizoncore-builder) only withholds its bearer token when the upload host ends in
      # .amazonaws.com, so on a self-hosted store it sends Authorization: Bearer alongside the
      # pre-signed query. S3 allows exactly one auth mechanism per request, so MinIO rejects it
      # with a 400 and the client reports "ETag not found in response headers". The header is
      # meaningless here anyway -- the pre-signed query is what authorises the PUT.
      printf '\thandle @s3 {\n\t\treverse_proxy minio:9000 {\n\t\t\theader_up -Authorization\n\t\t}\n\t}\n'
    fi
    if [ "${AUTH_MODE:-}" = "local" ]; then
      # Local user accounts (offline-capable). The auth sidecar serves the login form + admin API
      # on public paths; everything else is gated by forward_auth, which bounces unauthenticated
      # browsers to /login and returns 401 to API callers.
      printf '\t@authpub path /login /logout /auth/*\n'
      printf '\thandle @authpub {\n\t\treverse_proxy auth:9930\n\t}\n'
      # Admin-only data APIs (System page, and the tooling credentials which can sign for the whole
      # fleet): gate them on an admin session. The console hides their nav items to match.
      printf '\t@adminapi path /api/ops/* /api/credentials /api/credentials/*\n'
      printf '\thandle @adminapi {\n\t\tforward_auth auth:9930 {\n\t\t\turi /auth/verify-admin\n\t\t}\n\t\treverse_proxy console:80\n\t}\n'
      printf '\thandle {\n\t\tforward_auth auth:9930 {\n\t\t\turi /auth/verify\n\t\t\tcopy_headers X-Auth-User\n\t\t}\n\t\tencode gzip\n\t\treverse_proxy console:80\n\t}\n'
    elif [ -n "${GITHUB_CLIENT_ID:-}" ]; then
      printf '\thandle {\n\t\tencode gzip\n\t\treverse_proxy oauth2-proxy:4180\n\t}\n'
    else
      printf '\thandle {\n\t\tencode gzip\n\t\tbasic_auth {\n\t\t\t%s %s\n\t\t}\n\t\treverse_proxy console:80\n\t}\n' \
        "$CONSOLE_USER" "$CONSOLE_PASSWORD_HASH"
    fi
    printf '}\n'
  } > "$APP_DIR/caddy/Caddyfile"
  chmod 600 "$APP_DIR/caddy/Caddyfile"
}

if [ -n "${GITHUB_CLIENT_ID:-}" ]; then
  : "${OAUTH_ALLOWED_USERS:?set OAUTH_ALLOWED_USERS to the GitHub logins allowed in — an empty allowlist would let any GitHub account sign in}"
  # Deployment secret (not a user credential): generate once and keep it, so existing sessions
  # survive a re-run of this script.
  if ! grep -q '^OAUTH_COOKIE_SECRET=' "$APP_DIR/.env" 2>/dev/null; then
    # 32 hex chars = exactly the 32 bytes oauth2-proxy wants. `openssl rand -base64 32`
    # gives 44 chars and is REJECTED ("must be 16, 24, or 32 bytes").
    echo "OAUTH_COOKIE_SECRET=$(openssl rand -hex 16)" >> "$APP_DIR/.env"
  fi
  render_caddyfile
elif [ "${AUTH_MODE:-}" = "local" ]; then
  render_caddyfile
elif [ -n "$CONSOLE_PASSWORD_HASH" ]; then
  render_caddyfile
fi

say "7/8  certs + bring up the stack"
# The gateway cert must cover RAS_PUBLIC_HOST so devices reach the gateway by real DNS (no
# /etc/hosts ota.ce hack). Regenerate if it's missing that SAN — this re-issues the device CA,
# which is fine before any device has enrolled.
if [ -d ota-ce-gen ] && ! openssl x509 -in ota-ce-gen/server.crt -noout -text 2>/dev/null | grep -q "DNS:$RAS_PUBLIC_HOST"; then
  echo "   gateway cert lacks SAN $RAS_PUBLIC_HOST — regenerating certs"
  rm -rf ota-ce-gen
fi
[ -d ota-ce-gen ] || GATEWAY_ALT_NAMES="$RAS_PUBLIC_HOST" scripts/gen-server-certs.sh
# NB: plain `[ test ] && arr+=(...)` as a statement is a `set -e` landmine — a false test makes
# the script exit. Use if-blocks.
FILES=(-f compose.release.yaml)
if [ -n "$CONSOLE_PASSWORD_HASH" ] || [ -n "${GITHUB_CLIENT_ID:-}" ]; then
  FILES+=(-f compose.public.yaml)
fi
if [ -n "${GITHUB_CLIENT_ID:-}" ]; then
  FILES+=(-f compose.oauth2.yaml)
fi
# Opt-in: set MINIO_ROOT_PASSWORD in .env to keep targets in MinIO instead of on local disk.
# Needed for out-of-band uploads (torizoncore-builder `platform push`). On an instance that
# already has targets on disk, migrate them once — see the header of compose.s3.yaml.
if [ -n "${MINIO_ROOT_PASSWORD:-}" ]; then
  FILES+=(-f compose.s3.yaml)
fi
# `up` uses the locally-built ras and pulls only the missing images (no blanket pull that would
# choke on ras). --env-file makes the vars available for substitution.
docker compose "${FILES[@]}" --env-file "$APP_DIR/.env" up -d
# compose doesn't detect bind-mount *content* changes (Caddyfile, console nginx.conf/index.html),
# so force-recreate the proxies to pick up re-rendered/updated config on a re-run.
RECREATE=(console gateway provisioner)
# caddy must be recreated in EITHER login mode so it picks up the re-rendered Caddyfile.
if [ -n "$CONSOLE_PASSWORD_HASH" ] || [ -n "${GITHUB_CLIENT_ID:-}" ]; then
  RECREATE+=(caddy)
fi
if [ -n "${GITHUB_CLIENT_ID:-}" ]; then
  RECREATE+=(oauth2-proxy)
fi
docker compose "${FILES[@]}" --env-file "$APP_DIR/.env" up -d --force-recreate "${RECREATE[@]}"
echo "   waiting for ota-lith to become healthy…"
for _ in $(seq 1 100); do
  s=$(docker inspect -f '{{.State.Health.Status}}' "${PROJECT}-ota-lith-1" 2>/dev/null || echo starting)
  [ "$s" = healthy ] && break; sleep 3
done
echo "   ota-lith: ${s:-unknown}"

say "8/8  initialize the TUF repositories"
# reverse-proxy is internal-only, so hit it from a throwaway curl container on the compose network.
NET="${PROJECT}_default"
cinit(){ docker run --rm --network "$NET" curlimages/curl:latest -sS -H "Host: $1" -H "x-ats-namespace: default" "${@:2}"; }
cinit reposerver.ota.ce -X POST http://reverse-proxy/api/v1/user_repo  >/dev/null 2>&1 || true
cinit director.ota.ce   -X POST http://reverse-proxy/api/v1/admin/repo >/dev/null 2>&1 || true
code=$(cinit reposerver.ota.ce -o /dev/null -w '%{http_code}' http://reverse-proxy/api/v1/user_repo/root.json || echo '?')
echo "   user_repo/root.json -> $code"

chown -R "$ADMIN_USER:$ADMIN_USER" "$APP_DIR" || true
say "done"
docker compose "${FILES[@]}" ps
cat <<EOF

  ── access ─────────────────────────────────────────────────────────────
  Console      https://$RAS_PUBLIC_HOST        (login: $CONSOLE_USER / <your password>)
  Provision    open the console → "Provision device" — a SHORT-LIVED token is generated for you
               (tick "install the hardware reporter" for the full device view); copy the shown
               command and run it on the device as root. No /etc/hosts needed (real DNS gateway).
  Remote SSH   device page → "Remote access"; bastion = $RAS_PUBLIC_HOST
  ────────────────────────────────────────────────────────────────────────
EOF
if [ -z "$CONSOLE_PASSWORD_HASH" ]; then
  echo; echo "NOTE: no CONSOLE_PASSWORD_HASH set — the Caddy TLS+password front was NOT started."
  echo "      Re-run with CONSOLE_PASSWORD_HASH set to expose the console at https://$RAS_PUBLIC_HOST"
fi
