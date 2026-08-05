# Remote Access (`ras`)

A minimal, open remote-access server compatible with the unmodified Torizon **RAC** client
(`github.com/torizon/rac`). One small Rust binary = HTTP API + a `tough`-signed `remote-sessions`
TUF repo + an `russh` SSH bastion. State in SQLite. Design: [../docs/remote-access-design.md](../docs/remote-access-design.md).

The device opens an **outbound** SSH tunnel to the bastion; you reach it with
`ssh <user>@<public-host> -p <reverse_port>`. Nothing needs an inbound port on the device.

## Configuration (env vars)
| Var | Default | Meaning |
|---|---|---|
| `RAS_HTTP_ADDR` | `0.0.0.0:9080` | HTTP API (device + admin); reached via the gateway/console proxy, **internal only** |
| `RAS_BASTION_ADDR` | `0.0.0.0:2222` | SSH bastion control port (**must be publicly reachable**) |
| `RAS_BASTION_PUBLIC_HOST` | `127.0.0.1` | Public hostname devices + operators use (goes into `ra_server_url` and the TUF allow-list) |
| `RAS_SSH_USER` | `torizon` | Username shown in the operator `ssh` command |
| `RAS_PORT_RANGE_START` / `RAS_PORT_RANGE_COUNT` | `22000` / `4` | Reverse-tunnel port pool (**each must be publicly reachable**) |
| `RAS_DATA_DIR` | `/data` | SQLite + persistent bastion host key + TUF signing key |
| `RAS_UUID_HEADER` | `x-device-uuid` | Header the gateway sets from the verified client cert |
| `RAS_DEV_FALLBACK_UUID` | — | Dev/testing only: identify all device requests as this UUID when no gateway is present |

**Persistence matters**: `/data` holds the bastion host key and the TUF signing key. If those
change, devices that already pinned them (TOFU) will reject sessions. Keep `/data` on a volume.

## HTTP API
Device-facing (behind gateway mTLS; `x-device-uuid` injected):
`POST /public-keys` · `GET /sessions` · `GET /commands` · `GET /director/root.json` · `GET /director/remote-sessions.json`

Operator/admin (from the console):
- `POST /admin/sessions` `{uuid, operator_pubkey, ttl_secs?}` → `{reverse_port, expires_at, ssh_command}`
- `DELETE /admin/sessions/{uuid}` · `GET /admin/sessions`

## Deploy (compose)
Add a `ras` service (see the compose files). Publish the bastion + tunnel ports; keep `9080` internal:
```yaml
  ras:
    image: ${OTA_CE_NS}/ras:0.1.0        # or build: ./remote-access/ras
    restart: unless-stopped
    environment:
      - RAS_BASTION_PUBLIC_HOST=${RAS_PUBLIC_HOST}   # your public DNS name
      - RAS_SSH_USER=torizon
    volumes: [ ras-data:/data ]
    ports:
      - "2222:2222"
      - "22000-22003:22000-22003"
# volumes: { ras-data: {} }
```

### Gateway (nginx, the mTLS device gateway) — route `/ras/`
```nginx
location /ras/ {
    proxy_pass http://ras:9080/;
    proxy_set_header x-device-uuid $ssl_client_s_dn_cn;   # UUID from the verified client cert
    proxy_set_header Host $host;
}
```
The gateway already verifies device client certs; it must **strip any client-supplied**
`x-device-uuid` and set it only from the cert. (Adjust `$ssl_client_s_dn_cn` to however device
certs encode the UUID on this instance.)

### Console proxy — admin API
Add to the console nginx: `location /api/ras/ { proxy_pass http://ras:9080/admin/; }` so the
console can arm/stop sessions.

## Device side (`rac`)
Torizon OS ships `rac`. Provide `/etc/rac/client.toml` pointing at the gateway and reusing the
device's existing mTLS cert. `director_url` **must be explicit** (its default `/director/` would
collide with the OTA director):
```toml
[torizon]
url          = "https://<PUBLIC_HOST>/ras/"
director_url = "https://<PUBLIC_HOST>/ras/director/"
server_cert_path = "/var/sota/root.crt"
client_cert_path = "/var/sota/client.pem"
client_key_path  = "/var/sota/pkey.pem"

[device]
ssh_private_key_path = "/var/sota/rac_ssh_key"
local_tuf_repo_path  = "/var/sota/rac-uptane"

# MVP: log straight into the device's sshd as `torizon`
[device.session.target_host]
host_port            = "127.0.0.1:22"
authorized_keys_path = "/home/torizon/.ssh/authorized_keys"
# Recommended (isolated): comment the above and use spawned_sshd instead
# [device.session.spawned_sshd]
# sshd_path  = "/usr/sbin/sshd"
# config_dir = "/run/rac"
```
Then `systemctl restart rac` (or run the container).

## Go-live checklist (Debian home server)
1. Build/push the image (or `build:` in compose) and set `RAS_PUBLIC_HOST` to your dynamic-DNS name.
2. `docker compose up -d ras`.
3. **Router port-forward to the Debian server**: TCP `2222` (bastion) + `22000–22003` (tunnels).
4. Add the gateway `/ras/` route and the console `/api/ras/` proxy; reload nginx.
5. Put `client.toml` on a device; `systemctl restart rac`; confirm it appears via `GET /admin/sessions` is empty but `POST /public-keys` logged.
6. In the console (or `curl POST /api/ras/sessions`), arm a session; run the printed `ssh` command. 🎉

## Security notes
- Two layers: device mTLS (gateway) + a TUF-signed `remote-sessions` allow-list (bastion host key pinned by the device).
- The bastion accepts only registered device keys, only for `user=UUID`, and only honors the reverse-forward on that session's allocated port — no shell, no other ports.
- Single-operator simplification: `ras` holds the TUF signing key (both trust roles). Fine for self-hosted single-tenant.
