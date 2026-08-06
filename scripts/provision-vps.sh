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

say "5/8  build the ras image ($OTA_CE_NS/ras:$OTA_CE_TAG)"
docker build -t "$OTA_CE_NS/ras:$OTA_CE_TAG" remote-access/ras

say "6/8  .env + Caddyfile"
# Provisioning token: reuse the existing one if present, else generate + persist (so re-runs are stable).
PROVISION_TOKEN="${PROVISION_TOKEN:-$(grep -E '^PROVISION_TOKEN=' "$APP_DIR/.env" 2>/dev/null | cut -d= -f2)}"
[ -n "$PROVISION_TOKEN" ] || PROVISION_TOKEN="$(openssl rand -hex 12)"
# .env drives compose ${} substitution for the release stack (simple values, no '$').
cat > "$APP_DIR/.env" <<EOF
OTA_CE_NS=$OTA_CE_NS
OTA_CE_TAG=$OTA_CE_TAG
RAS_PUBLIC_HOST=$RAS_PUBLIC_HOST
RAS_SSH_USER=$RAS_SSH_USER
CONSOLE_BIND=127.0.0.1
PROVISION_TOKEN=$PROVISION_TOKEN
EOF
# Render the Caddyfile with values inlined (incl. the bcrypt hash) — no env-var indirection, so
# compose's interpolation can't mangle the hash's '$' chars. Only when a hash is provided.
if [ -n "$CONSOLE_PASSWORD_HASH" ]; then
  cat > "$APP_DIR/caddy/Caddyfile" <<EOF
{
	email $ACME_EMAIL
}

$RAS_PUBLIC_HOST {
	encode gzip
	# Device enrollment is gated by PROVISION_TOKEN (not the console password), so these paths
	# bypass basic_auth — a device can enroll with the token without the shared login.
	@provision path /provision-device.sh /api/provision /api/provision/*
	handle @provision {
		reverse_proxy console:80
	}
	handle {
		basic_auth {
			$CONSOLE_USER $CONSOLE_PASSWORD_HASH
		}
		reverse_proxy console:80
	}
}
EOF
  chmod 600 "$APP_DIR/caddy/Caddyfile"
fi

say "7/8  certs + bring up the stack"
[ -d ota-ce-gen ] || scripts/gen-server-certs.sh
FILES=(-f compose.release.yaml)
[ -n "$CONSOLE_PASSWORD_HASH" ] && FILES+=(-f compose.public.yaml)
# `up` uses the locally-built ras and pulls only the missing images (no blanket pull that would
# choke on ras). --env-file makes the vars available for substitution.
docker compose "${FILES[@]}" --env-file "$APP_DIR/.env" up -d
# compose doesn't detect Caddyfile *content* changes (bind mount), so force-recreate caddy to
# pick up a re-rendered config (e.g. after changing RAS_PUBLIC_HOST / the password).
[ -n "$CONSOLE_PASSWORD_HASH" ] && docker compose "${FILES[@]}" --env-file "$APP_DIR/.env" up -d --force-recreate caddy
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
  Provision    on the device, map the gateway host then enroll with the token:
     echo "<THIS_VPS_IP> ota.ce" | sudo tee -a /etc/hosts
     curl -fsSL https://$RAS_PUBLIC_HOST/provision-device.sh | sudo bash -s -- \\
          -s https://$RAS_PUBLIC_HOST -n <device-name> -t $PROVISION_TOKEN
  Remote SSH   device page → "Remote access"; bastion = $RAS_PUBLIC_HOST
  ────────────────────────────────────────────────────────────────────────
EOF
if [ -z "$CONSOLE_PASSWORD_HASH" ]; then
  echo; echo "NOTE: no CONSOLE_PASSWORD_HASH set — the Caddy TLS+password front was NOT started."
  echo "      Re-run with CONSOLE_PASSWORD_HASH set to expose the console at https://$RAS_PUBLIC_HOST"
fi
