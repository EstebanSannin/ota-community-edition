# Operating the server — logs, health & housekeeping

How to see what the OTA server is doing and debug it, from your laptop or on the VPS.

The public instance runs 8 Docker containers under one Compose project
(`ota-community-edition`). Everything below works over SSH; nothing is exposed publicly.

## 1. Get onto the VPS

```bash
ssh -i ~/.ssh/ota_ce_vm root@ota.samnium.tech
# (or root@116.203.91.174 if DNS is slow)
```

All commands below assume you are on the VPS. The project lives in
`/opt/ota-community-edition`.

## 2. The services

| Service        | Container name                          | What it is |
|----------------|-----------------------------------------|------------|
| `ota-lith`     | `ota-community-edition-ota-lith-1`      | The OTA monolith (director, repo server, device-registry). The one you'll read most. |
| `db`           | `ota-community-edition-db-1`            | MariaDB (backing store for ota-lith). |
| `gateway`      | `ota-community-edition-gateway-1`       | Device-facing TLS gateway (mTLS, port 30443). |
| `ras`          | `ota-community-edition-ras-1`           | Remote access: SSH bastion + web-terminal + session API. |
| `provisioner`  | `ota-community-edition-provisioner-1`   | Device enrollment + token minting + install scripts. |
| `console`      | `ota-community-edition-console-1`       | The web console (nginx serving the SPA + API proxy). |
| `caddy`        | `ota-community-edition-caddy-1`         | Public TLS front + password wall. |
| `reverse-proxy`| `ota-community-edition-reverse-proxy-1` | Internal router in front of ota-lith. |

Quick status of everything:

```bash
docker ps --format 'table {{.Names}}\t{{.Status}}'
```

`Up … (healthy)` on `ota-lith` and `db` means their healthchecks pass.

## 3. Reading logs

Two ways. `docker logs <container>` is simplest; `docker compose logs <service>` can
show several services together. On the VPS you can use either.

### Follow one service live (the everyday command)

```bash
docker logs -f --tail 100 ota-community-edition-ota-lith-1
```

- `-f` follow (live tail — Ctrl-C to stop)
- `--tail 100` start with the last 100 lines
- add `--timestamps` to prefix each line with a UTC time

### Only recent lines

```bash
docker logs --since 15m ota-community-edition-ras-1      # last 15 minutes
docker logs --since 2026-08-06T13:00:00 ota-community-edition-gateway-1
```

### Search

```bash
docker logs ota-community-edition-ota-lith-1 2>&1 | grep -iE 'error|warn|exception'
docker logs ota-community-edition-ras-1     2>&1 | grep -i 'web-terminal'
```

> Most services log to **stderr**, so keep the `2>&1` when piping to `grep`/`less`.

### All services at once (project-wide)

From `/opt/ota-community-edition`:

```bash
cd /opt/ota-community-edition
docker compose -f compose.release.yaml -f compose.public.yaml --env-file .env logs -f --tail 50
# one service, same syntax:
docker compose -f compose.release.yaml -f compose.public.yaml --env-file .env logs -f ota-lith
```

(The long `-f compose.* --env-file .env` prefix is how this instance was brought up.
`docker logs <container>` needs none of it.)

### What each service is good for

- **Device won't provision / update** → `ota-lith` (and `gateway` for the mTLS handshake).
- **Console login / password / TLS cert** → `caddy`.
- **Console API 502 / proxy errors** → `console` (nginx).
- **Remote access / web terminal** → `ras` (look for `armed session`, `bastion:`, `web-terminal:`).
- **Enrollment token / install script** → `provisioner`.

## 4. Host-level logs & resources

```bash
# live resource usage per container (Ctrl-C to stop)
docker stats

# one-shot snapshot
docker stats --no-stream --format 'table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}'

# disk
df -h /
docker system df                 # image/volume/build-cache usage

# the Docker daemon itself (host journal)
journalctl -u docker --no-pager -n 100
```

## 5. Restarting things

```bash
docker restart ota-community-edition-ota-lith-1        # restart one service

# after editing a bind-mounted config (Caddyfile, nginx.conf, index.html) the file
# changes on disk but the running container keeps the old one — restart to pick it up:
docker restart ota-community-edition-console-1
```

## 6. Housekeeping (do this occasionally)

**Log rotation is currently OFF** — container logs grow forever and can eventually fill
the disk. Fix it once, host-wide, by creating `/etc/docker/daemon.json`:

```json
{
  "log-driver": "json-file",
  "log-opts": { "max-size": "10m", "max-file": "5" }
}
```

then `systemctl restart docker` and recreate the stack. New containers keep at most
5 × 10 MB of logs each. (This is also worth baking into `scripts/provision-vps.sh`.)

Reclaim space from old images / build cache:

```bash
docker system df                 # see what's reclaimable
docker builder prune -f          # build cache (safe)
docker image prune -f            # dangling images (safe)
```

## 7. Back up the things you can't regenerate

If the VPS dies, these are the only pieces you can't rebuild from git — **losing the
TUF keys means every device must be re-provisioned**:

```bash
# ras keys (bastion host key, web-terminal console key, remote-sessions TUF key + db)
docker run --rm -v ota-community-edition_ras-data:/d -v /root:/out alpine \
  tar czf /out/ras-data-backup.tar.gz -C /d .

# the OTA repo/TUF state + MariaDB live in named volumes too:
docker volume ls | grep ota-community-edition
```

Copy those tarballs off the box (e.g. `scp` to your laptop) and keep them safe.

## 8. The System page (in-console observability)

The console has a **System** section (left nav) showing service status, CPU/memory/disk,
and **live logs** per service — no SSH needed. It's powered by `compose.observability.yaml`: a
read-only `docker-socket-proxy` (GET-only) plus a small `ops` sidecar. The `ops` service never
touches the raw Docker socket.

**`bootstrap.sh` includes this by default**, so a fresh local install has a working System page out
of the box — set `OBSERVABILITY=0` to skip it. When local-users auth is in front, the System page is
**admin-only** (its `/api/ops` data is gated on an admin session). For an existing deployment you
manage by hand, add the overlay to your deploy:

```bash
cd /opt/ota-community-edition
docker build -t "$OTA_CE_NS/ota-ce-ops:$OTA_CE_TAG" ops
docker compose -f compose.release.yaml -f compose.public.yaml -f compose.observability.yaml \
  --env-file .env up -d
```

> Whenever you enable the overlay, keep the `-f compose.observability.yaml` in your deploy
> commands. If you run `up -d --remove-orphans` with only the release + public files, Compose
> will remove `ops` and `socket-proxy`. (Plain `up -d` without `--remove-orphans` leaves them.)

Everything the System page shows is also available from the CLI (sections 1–4 above); the page
is just a convenience layer over the same Docker data.

## 9. Object storage for targets (S3 / MinIO)

The public instance keeps TUF targets in a bundled MinIO rather than on local disk, because
out-of-band uploads — `torizoncore-builder platform push` — are refused by the local-disk backend.
See [tooling-credentials.md](tooling-credentials.md) for the full workflow; the overlay is
`compose.s3.yaml` and it is enabled by setting `MINIO_ROOT_PASSWORD` in `.env`.

The full deploy line for this instance is therefore:

```bash
docker compose -f compose.release.yaml -f compose.public.yaml -f compose.oauth2.yaml \
  -f compose.observability.yaml -f compose.s3.yaml --env-file .env up -d
```

Two things that will bite you:

- **`ota-lith` carries a patch** that lets the reposerver talk to a non-AWS S3 endpoint. As of
  **0.2.0 this patch is in the published image**, so `docker compose pull` is safe (before 0.2.0 it
  would have silently rolled back to a build whose only working storage backend was local disk).
  Rebuild it locally with:

  ```bash
  docker run --rm -v /opt/ota-community-edition:/src -w /src \
    -v ota-sbt-cache:/root/.cache -v ota-sbt-ivy:/root/.ivy2 -v ota-sbt-sbt:/root/.sbt \
    -e SBT_OPTS=-Xmx3g sbtscala/scala-sbt:eclipse-temurin-jammy-21.0.2_13_1.9.9_3.4.1 \
    sbt -batch "Docker / stage"
  docker build -t "$OTA_CE_NS/ota-lith:$OTA_CE_TAG" target/docker/stage
  ```

- **Recreating `ota-lith` gives it a new container IP, and the nginx proxies cache the old one.**
  `console`, `reverse-proxy` and `gateway` then answer `502` — including for devices. Restart them
  after any `up -d` that recreated `ota-lith`:

  ```bash
  docker restart ota-community-edition-console-1 \
    ota-community-edition-reverse-proxy-1 ota-community-edition-gateway-1
  ```
