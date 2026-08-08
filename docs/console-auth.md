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

## Adding or removing people

Access is an **allowlist of GitHub logins** in `OAUTH_ALLOWED_USERS` (`.env`), which the compose
overlay passes to oauth2-proxy as `OAUTH2_PROXY_GITHUB_USERS`. Anyone not on the list can
authenticate with GitHub but is then refused with a **403** — nothing else is needed on GitHub's
side (the OAuth app is standard; any GitHub user can consent, the allowlist is the only gate).

To add a colleague:

```bash
cd /opt/ota-community-edition
# edit .env — append their GitHub LOGIN, comma-separated, no spaces:
#   OAUTH_ALLOWED_USERS=EstebanSannin,theirlogin
sudo docker compose -f compose.release.yaml -f compose.public.yaml -f compose.oauth2.yaml \
  -f compose.observability.yaml -f compose.s3.yaml --env-file .env up -d oauth2-proxy
```

Removing someone is the same edit in reverse. Confirm what oauth2-proxy actually loaded:

```bash
docker inspect ota-community-edition-oauth2-proxy-1 \
  --format '{{range .Config.Env}}{{println .}}{{end}}' | grep GITHUB_USERS
```

Three things that have each caused a wasted round:

- **It's the GitHub login (username), not the email.** `EstebanSannin`, not `you@example.com`.
  An email there authenticates and then 403s.
- **`up -d` (recreate), not `docker restart`.** Env vars are fixed when the container is created,
  so a plain restart keeps the *old* allowlist. Recreating with `--env-file` picks up the change.
- **Never leave it empty** — an empty allowlist lets *any* GitHub account sign in.

> **Adding someone grants full access.** GitHub mode has **no roles** — everyone allowed in is equal
> and gets everything, including the **web terminal** (a root shell on your devices) and
> **Settings → Tooling credentials** (the `credentials.zip` that signs packages your whole fleet
> trusts). Only add people you'd trust with the fleet. If you need *limited* access (e.g. view-only),
> that's the admin/non-admin split in **local user accounts** below — a different, mutually-exclusive
> front, not GitHub.

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

---

# Alternative: local user accounts (offline)

GitHub sign-in needs the internet and a GitHub account per operator. For a LAN or air-gapped
instance — or anywhere you don't want that dependency — use **local users** instead: per-user,
revocable accounts stored on the instance itself, with no external identity provider.

This is a third front mode, sitting beside "none" (open, for a trusted LAN) and GitHub. The console
itself is unchanged in all three — login lives entirely in Caddy, which delegates to the small `auth`
sidecar via `forward_auth`.

## How it fits together

```
browser ──https──▶ Caddy ──forward_auth──▶ auth sidecar   (session cookie? 2xx allow : 302 /login)
                     │                       └ /login, /logout, /auth/api/users …
                     ├── /provision-device.sh, /api/provision …  (device enrollment: NOT gated)
                     └── /tuf/*  (tooling: bearer-token, NOT gated)
                                  everything else ──▶ console
```

## Turn it on

Set `AUTH_MODE=local` in `.env`, plus `LOCAL_TLS=1` if you have no public DNS / Let's Encrypt (Caddy
then issues its own certificate from a built-in CA). Re-render the Caddyfile and bring the overlay up:

```bash
cd /opt/ota-community-edition
printf 'AUTH_MODE=local\nLOCAL_TLS=1\nRAS_PUBLIC_HOST=ota.local\n' | sudo tee -a .env
AUTH_MODE=local LOCAL_TLS=1 scripts/provision-vps.sh          # or just re-render caddy/Caddyfile
sudo docker compose -f compose.release.yaml -f compose.public.yaml -f compose.auth.yaml \
  --env-file .env up -d
```

On first start, if no users exist, an **admin** account is created with a random password printed
**once** to the logs — log in and change it from the **Users** page:

```bash
docker logs ota-community-edition-auth-1 | grep -A2 'initial administrator'
```

(Set `AUTH_ADMIN_PASSWORD` in `.env` to choose that first password instead of a random one.)

## Managing users

The console gains a **Users** section (visible only when local-users auth is in front): add a user,
reset a password, or delete one. Deleting a user — or resetting their password — **ends their active
sessions immediately**, not just their next login. The last remaining user cannot be deleted, so you
can't lock everyone out.

## Notes

- **Session cookies are `Secure`** (HTTPS-only), so this mode assumes a TLS front — which
  `LOCAL_TLS=1` gives you offline. For a plain-HTTP test only, set `AUTH_COOKIE_SECURE=0`.
- **Passwords** are stored salted + hashed (scrypt, or PBKDF2 where scrypt is unavailable), never in
  plain text. The database lives in the `auth-data` volume — back it up with the rest of your state.
- Device enrollment and the `/tuf` tooling path bypass the login in this mode too, so provisioning
  and `torizoncore-builder` keep working regardless of who can log in.
- Reaching it from another machine on the LAN: point that machine's DNS/hosts at the instance for
  the name in `RAS_PUBLIC_HOST` (e.g. `192.168.64.2 ota.local`) and trust Caddy's local root CA (or
  accept the browser warning once).
