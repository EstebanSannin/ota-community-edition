# Deploying OTA CE on a public VPS (single-tenant, password-gated)

Goal: put the whole instance on a public VPS so friends/colleagues can try it, gated by one
shared password over HTTPS. Single-tenant (one shared device list) for now — see "Later" at the end
for the multi-tenant / GitHub-login roadmap.

## 0. What you need
- A small VPS. **Hetzner Cloud CX33** (4 vCPU Intel / 8 GB / 80 GB NVMe / 20 TB, ~€8.49/mo) is the
  sweet spot — `ota-lith` is a JVM app and likes RAM. The 4 GB tier one step down works if tight.
  (An Arm CAX plan is a bit cheaper and fine too — our images are multi-arch.) Debian 12/13.
  Order at https://console.hetzner.com/ .
- A **domain** (or subdomain) you control, e.g. `ota.example.com`, with an **A record → the VPS IP**.
  Used for the console (real HTTPS cert) and the SSH bastion.

## 1. One hostname
Everything uses your real domain **`ota.example.com`** (public DNS → VPS):
- **console** — Caddy TLS + password.
- **device mTLS gateway** (`:30443`) — the gateway cert is issued (by the instance CA) with your
  domain as a SAN, so devices verify it over normal DNS. **No `/etc/hosts` on devices.**
- **SSH bastion** — devices + your laptop reach it here.

(The internal placeholder `ota.ce` is still a SAN for backward-compat, but nothing needs it.)

## 2. Firewall (ufw) — only these ports public
```bash
ufw default deny incoming
ufw allow 22/tcp                 # your SSH admin (consider limiting to your IP)
ufw allow 80,443/tcp             # console (Caddy: ACME + HTTPS)
ufw allow 30443/tcp              # device mTLS gateway
ufw allow 2222/tcp               # remote-access bastion control
ufw allow 22000:22003/tcp        # remote-access tunnels (4 concurrent sessions)
ufw enable
```
The database (`127.0.0.1:3306`) and the internal reverse-proxy are **not** published — they stay on
the docker network, unreachable from the internet.

## 3. Install Docker + clone
```bash
apt update && apt install -y docker.io docker-compose-plugin git
git clone -b greenfield-boot-fixes https://github.com/EstebanSannin/ota-community-edition.git
cd ota-community-edition
```

## 4. Configure (`.env` in the repo root)
```bash
OTA_CE_NS=samnite
OTA_CE_TAG=latest
RAS_PUBLIC_HOST=ota.example.com          # console domain + bastion host
ACME_EMAIL=you@example.com               # Let's Encrypt
RAS_SSH_USER=torizon
CONSOLE_BIND=127.0.0.1                    # keep the raw console off the public interface
CONSOLE_USER=admin
CONSOLE_PASSWORD_HASH=<paste hash>        # see below
```
Generate the password hash:
```bash
docker run --rm caddy caddy hash-password --plaintext 'the-shared-password'
```

## 5. Images
`ota-lith` + `ota-ce-provisioner` are pulled from `$OTA_CE_NS`. Build `ras` locally (it's small):
```bash
docker build -t $OTA_CE_NS/ras:latest remote-access/ras
```
(or `NS=$OTA_CE_NS ./release.sh` to build+push all three from a build host.)

## 6. Bring it up
```bash
./bootstrap.sh                                   # generates certs (ota-ce-gen/) then starts the release stack
docker compose -f compose.release.yaml -f compose.public.yaml up -d   # add Caddy TLS+password front
```
Visit `https://ota.example.com` → browser asks for the shared password → the console.

## 7. Provision a device (per device)
Open the console → **Provision device**: it generates a **short-lived enrollment token** and shows a
copy-ready command (tick **"install the hardware reporter"** for the full device view). Run it on the
device **as root** — no `/etc/hosts`, nothing to pre-install:
```bash
curl -fsSL https://ota.example.com/provision-device.sh | sudo bash -s -- \
  -s https://ota.example.com -n my-device -t <token-from-the-dialog> -r
```
For remote access, drop in the RAC config (edit the gateway host to your domain) and start it:
```bash
sudo cp remote-access/client.toml.example /etc/rac/client.toml   # see remote-access/README.md
sudo systemctl restart rac aktualizr-torizon
```

## 8. Use it
- **Console** (you + friends): `https://ota.example.com` with the shared password.
- **Provisioning**: each operator generates their own short-lived token in the Provision dialog.
- **Remote access**: device page → Remote Access → the `ssh` command targets `ota.example.com`.
- **Devices**: gateway `ota.example.com:30443` (mTLS) + bastion `ota.example.com:2222` — all real DNS.

## Security notes
- The shared password protects the **console + its API**. Devices (mTLS) and the bastion (SSH keys)
  keep their own strong auth. The DB and internal services are not exposed.
- Rotate the password by regenerating the hash and `docker compose … up -d caddy`.
- Consider limiting SSH (22) to your own IP.

## Later (the roadmap, not today)
- **Real login**: swap Caddy's `basic_auth` for **oauth2-proxy** (GitHub/Google) via `forward_auth` —
  same `reverse_proxy console:80` target. Gives per-user login without a shared password.
- **Multi-tenant** (company account, per-user device lists, shared sub-accounts): a backend change —
  the device-registry/namespaces would key on an authenticated user/org, and the console would scope
  lists per identity. Bigger effort; the single-tenant setup here is the stepping stone.
