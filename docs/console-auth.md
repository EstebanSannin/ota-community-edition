# Console login: per-user GitHub sign-in

By default the public console sits behind one shared password (Caddy `basic_auth`). That works, but
everyone who can open the console shares a single secret, and a secret you've shared can't be
un-shared. This replaces it with **per-user GitHub sign-in**, so access is an allowlist of GitHub
logins you can add to and revoke individually.

Why this matters beyond tidiness: the console can open a **root-ish shell on your devices** (the web
terminal). Whoever can log in can do that. Per-user login means you can hand access to someone and
take it away again.

> **GitHub only.** `oauth2-proxy` supports one provider per instance — multi-provider is an
> incomplete upstream feature. For GitHub *and* Google you'd put an identity broker (e.g. Dex) in
> front, which is a larger change.

## How it fits together

```
browser ──https──▶ Caddy ──▶ oauth2-proxy ──▶ console
                     │           (GitHub login, allowlist)
                     └── /provision-device.sh, /api/provision …  ──▶ console
                         (device enrollment: NOT behind the login — gated by a
                          short-lived provisioning token instead)
```

Enrollment deliberately stays in Caddy, so devices can still be provisioned even if oauth2-proxy is
down or misconfigured.

## 1. Create the GitHub OAuth app

On GitHub: **Settings → Developer settings → OAuth Apps → New OAuth App**

| Field | Value |
|---|---|
| Application name | anything, e.g. `OTA Console` |
| Homepage URL | `https://ota.samnium.tech` |
| Authorization callback URL | `https://ota.samnium.tech/oauth2/callback` |

The callback URL must match **exactly** — that's the most common setup mistake.

Then "Generate a new client secret" and keep the page open; you need the **Client ID** and the
**Client secret** in the next step. Treat the secret like a password.

## 2. Put the credentials on the server

SSH to the VPS and append them to the env file. Do this yourself — the secret should not travel
through anything else:

```bash
sudo tee -a /opt/ota-community-edition/.env >/dev/null <<'EOF'
GITHUB_CLIENT_ID=<your client id>
GITHUB_CLIENT_SECRET=<your client secret>
OAUTH_ALLOWED_USERS=<your-github-login>
EOF
```

`OAUTH_ALLOWED_USERS` is a comma-separated list of GitHub logins. **Never leave it empty** — an
empty allowlist would let any GitHub account on the internet sign in. Adding a friend later is just
appending their login and restarting oauth2-proxy.

Generate the cookie-signing secret (a deployment secret, not your credential). Use `-hex 16`:
it gives exactly the 32 bytes oauth2-proxy requires, whereas `openssl rand -base64 32` produces 44
characters and is rejected.

```bash
grep -q '^OAUTH_COOKIE_SECRET=' /opt/ota-community-edition/.env || \
  echo "OAUTH_COOKIE_SECRET=$(openssl rand -hex 16)" | sudo tee -a /opt/ota-community-edition/.env >/dev/null
```

## 3. Switch the front over

```bash
cd /opt/ota-community-edition
sudo docker compose -f compose.release.yaml -f compose.public.yaml -f compose.oauth2.yaml \
  -f compose.observability.yaml --env-file .env up -d
```

Then re-render the Caddyfile so Caddy proxies to oauth2-proxy instead of asking for the password —
re-running `scripts/provision-vps.sh` with `GITHUB_CLIENT_ID` set does this for you, or edit
`caddy/Caddyfile` and replace the `handle { basic_auth … }` block with:

```
	handle {
		reverse_proxy oauth2-proxy:4180
	}
```

then `sudo docker restart ota-community-edition-caddy-1`.

## If you lock yourself out

The raw console stays bound to localhost (`CONSOLE_BIND=127.0.0.1`), so you always have a way in
that bypasses the login entirely:

```bash
ssh -L 8080:127.0.0.1:8080 root@ota.samnium.tech
# then open http://localhost:8080 in your browser
```

That's the escape hatch if the callback URL is wrong, the allowlist is empty, or oauth2-proxy won't
start. To go back to the shared password, remove `GITHUB_CLIENT_ID` from `.env`, re-render the
Caddyfile with `CONSOLE_PASSWORD_HASH` set, and restart Caddy.

## Checking it

```bash
docker logs ota-community-edition-oauth2-proxy-1 | tail -20
curl -s -o /dev/null -w '%{http_code} %{redirect_url}\n' https://ota.samnium.tech/
```

An unauthenticated request should answer `302` and redirect to `github.com/login/oauth/authorize…`.
A `500` usually means a missing env var; `403` after signing in means your login isn't in
`OAUTH_ALLOWED_USERS`.

Device enrollment must keep working without a login — worth re-checking after the switch:

```bash
curl -s -o /dev/null -w '%{http_code}\n' https://ota.samnium.tech/provision-device.sh   # expect 200
```
