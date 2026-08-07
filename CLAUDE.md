# Working notes for Claude

A **self-hostable OTA cloud** for embedded Linux (Torizon OS) devices: provision a device, publish a
package, deploy it over the air — built on TUF/Uptane. This is a greenfield fork of the
microservice-era community edition, optimised for *running on one machine and being easy to
understand*. Live instance: `https://ota.samnium.tech` (Hetzner VPS, Debian 13).

**Read [docs/architecture.md](docs/architecture.md) before making structural changes** — it explains
how the pieces fit and, more importantly, *why* they were chosen. Open work is in
[docs/roadmap.md](docs/roadmap.md).

## The shape of it

`ota-lith` is **one JVM process** running four Uptane services, each on its own port. The
`device-registry` is merged into the director (not a separate service); `campaigner` is gone.

| Port | Service | Notes |
|---|---|---|
| 7100 | reposerver | image repo: targets + delegations. Stores target blobs (local disk or S3) |
| 7200 | keyserver | holds the TUF signing keys |
| 7300 | director | per-device metadata, assignments, offline-updates (Lockbox) + `/device-registry/` |
| 7400 | treehub | OSTree object store |

Everything else is small and deliberately boring — **stdlib-only Python sidecars** and static files:

| Service | Port | Job |
|---|---|---|
| `console` | 8080→80 | static SPA (ES modules, **no framework, no build step**) + nginx API proxy |
| `provisioner` | 9900 | serves `provision-device.sh`, mints device credentials + enrollment tokens |
| `ras` | 9080, 2222, 22000-3 | remote access (reverse-SSH bastion, RAC-compatible). Rust |
| `ops` | 9910 | System page: container status, resources, SSE log streaming |
| `lockbox` | 9920 | offline-update `.zip` exporter, `credentials.zip`, tooling token endpoint |
| `gateway` | 30443→8443 | **device-facing** nginx: mTLS client certs |
| `reverse-proxy` | 80 | internal host-based router to the ota-lith ports |
| `caddy` | 80/443 | public TLS + login (only in the VPS deploy) |

Two separate auth planes, and they are easy to confuse: **humans** sign in with GitHub via
oauth2-proxy; **tooling** (torizoncore-builder/garage-sign) uses a client-credentials token from our
own endpoint, because GitHub cannot serve that grant. See [docs/console-auth.md](docs/console-auth.md)
and [docs/tooling-credentials.md](docs/tooling-credentials.md).

## Commands

Local/LAN bring-up (generates certs, then `up -d`):

```bash
OTA_CE_NS=samnite ./bootstrap.sh
```

The live VPS runs **five** compose files. Leaving one out and adding `--remove-orphans` deletes those
services:

```bash
docker compose -f compose.release.yaml -f compose.public.yaml -f compose.oauth2.yaml \
  -f compose.observability.yaml -f compose.s3.yaml --env-file .env up -d
```

Rebuild `ota-lith` (no JDK/sbt on the dev Mac — build it in a container, on the VPS):

```bash
docker run --rm -v /opt/ota-community-edition:/src -w /src \
  -v ota-sbt-cache:/root/.cache -v ota-sbt-ivy:/root/.ivy2 -v ota-sbt-sbt:/root/.sbt \
  -e SBT_OPTS=-Xmx3g sbtscala/scala-sbt:eclipse-temurin-jammy-21.0.2_13_1.9.9_3.4.1 \
  sbt -batch "Docker / stage"
docker build -t "$OTA_CE_NS/ota-lith:$OTA_CE_TAG" target/docker/stage
```

Before deploying any console change (there is no bundler to catch this):

```bash
python3 scripts/check-console-modules.py
```

Server logs, resources and the System page: [docs/operations.md](docs/operations.md).

## Rules that came from real breakages

Each of these cost real debugging time. They are not style preferences.

1. **Package metadata must stay ASCII.** One em dash in a description made `targets.json` 3829 bytes
   but 3827 characters, and *every device in the fleet* rejected the image-repo metadata. Use
   `asciiSafe()` (`console/js/lib/api.js`) on anything user-entered that reaches target metadata.
2. **Never compress anything TUF.** TUF pins the sha256 **and length** of exact bytes, so a gzipped
   response can never verify. `proxy_set_header Accept-Encoding "";` appears in *every* location of
   `ota-ce/gateway.conf` — nginx **discards** a server-level `proxy_set_header` in any location that
   defines its own. In Caddy, keep `encode gzip` scoped to the browser handle only.
3. **Recreating `ota-lith` changes its container IP, and the nginx proxies cache the old one.**
   `console`, `reverse-proxy` and `gateway` then 502 — *including for devices*. Always:
   `docker restart ota-community-edition-{console,reverse-proxy,gateway}-1`.
4. **`ota-lith` carries a local patch — check the registry image has it before pulling.** The
   reposerver is patched to accept a non-AWS S3 endpoint; an unpatched image silently supports only
   local-disk storage. `samnite/ota-lith:0.2.0`/`:latest` **do** contain it (verified 2026-08-07), so
   pulling is safe today. If you ever rebuild from a machine whose tree lacks the patch, you can undo
   that guarantee. Rollback tag on the VPS: `samnite/ota-lith:prerollback-s3`. Verify with:
   `python3 -c "import zipfile;print(b'publicEndpointUrl' in zipfile.ZipFile('repo.jar').read('com/advancedtelematic/tuf/reposerver/target_store/S3TargetStoreEngine.class'))"`
5. **Single-file bind mounts pin the inode.** After editing `console/index.html` or an `nginx.conf`
   on the host, `docker restart` the container or it keeps serving the old file. Directory mounts
   (`console/js/`) pick changes up on their own.
6. **Test device updates on the Verdin (`ssh real-dev`), not the QEMU.** The QEMU runs Torizon OS
   *Minimal* — no Docker at all, so compose installs always fail there.
7. **Each device Secondary keeps its OWN TUF store** (`/var/sota/storage/*/sql.db`), separate from
   `/var/sota/sql.db`. A board previously registered elsewhere rejects our metadata with `A key has
   an incorrect associated key ID`. `provision-device.sh` clears it; if you see that error, that is
   the cause.
8. **`caddy/Caddyfile` is generated and gitignored** (it inlines secrets). Edit
   `scripts/provision-vps.sh` (`render_caddyfile`) and the `.example` template instead.
9. **Commit with `git commit -F <file>`.** Backticks in a `-m` message get executed by the shell and
   silently mangle the text.
10. **In `provision-vps.sh`, use `if` blocks, not `[ test ] && cmd`** as a statement — under `set -e`
    a false test exits the script.

## Conventions

- **Python sidecars: stdlib only, no pip, no frameworks.** Small and human-readable, on
  `ThreadingHTTPServer`. Follow the existing shape in `ops/serve.py` / `lockbox/serve.py`.
- **Console: ES modules, no bundler.** One module per view in `console/js/views/`, shared helpers in
  `console/js/lib/`, the only cross-view state in `console/js/state.js`. Inline `on*=` handlers need
  `expose({...})` at the end of the module. No local `node` — syntax-check by stripping
  `import`/`export` lines and running the file through `osascript -l JavaScript`.
- **Comments explain *why*, not what** — especially for anything non-obvious enough to look wrong.
  Match the surrounding density; keep source ASCII.
- **`repos/` is vendored upstream Scala, tracked in this repo.** Patching it is allowed and
  sometimes necessary, but keep changes surgical and preserve upstream behaviour on the default path
  (e.g. gate new behaviour on a config value being set).

## What "done" means here

This project talks to real hardware, so **verify against the live instance or a device rather than
reasoning that it should work**. A change is done when it has been exercised end to end — and when a
verification fails, find out *why* before concluding it is unrelated: a failure that looks like a
regression has more than once been pre-existing device state, and the reverse is also true. Say
plainly what was verified and what was not.
