# Working notes for Claude

A **self-hostable OTA cloud** for embedded Linux (Torizon OS) devices: provision a device, publish a
package, deploy it over the air — built on TUF/Uptane. This is a greenfield fork of the
microservice-era community edition, optimised for *running on one machine and being easy to
understand*. Live instance: `https://ota.samnium.tech` (Hetzner VPS, Debian 13).

**Read [docs/architecture.md](docs/architecture.md) before making structural changes** — it explains
how the pieces fit and, more importantly, *why* they were chosen. Open work is in
[docs/roadmap.md](docs/roadmap.md).

## Docs

- [architecture.md](docs/architecture.md) — how the pieces fit + *why* (read before structural changes)
- [operations.md](docs/operations.md) — running it: the full service list, logs, resources, System page, S3
- [vps-deploy.md](docs/vps-deploy.md) — standing up a public instance (DNS, TLS, firewall, overlays)
- [console-auth.md](docs/console-auth.md) — login modes: none / local users / GitHub
- [tooling-credentials.md](docs/tooling-credentials.md) — `credentials.zip` + `torizoncore-builder`
- [offline-updates.md](docs/offline-updates.md) — building + installing a Lockbox
- [remote-access-design.md](docs/remote-access-design.md) — reverse-SSH / web terminal (the `ras` service)
- [upstream-divergence.md](docs/upstream-divergence.md) — how `repos/` tracks uptane/* + the update log
- [torizon-api-compat.md](docs/torizon-api-compat.md) — API-compat evaluation
- [roadmap.md](docs/roadmap.md) — what's not done yet
- [status-report.md](docs/status-report.md) — historical greenfield bring-up record

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
| `ops` | 9910 | System page: container status, resources, SSE log streaming (observability overlay, on by default) |
| `lockbox` | 9920 | offline-updates, `credentials.zip` + tooling token endpoint, and the bearer-auth `/tuf` + `/director` proxy for torizoncore-builder |
| `auth` | 9930 | local-users login (`AUTH_MODE=local`): sessions, user CRUD, forward_auth hook. Admin/non-admin roles |
| `gateway` | 30443→8443 | **device-facing** nginx: mTLS client certs |
| `reverse-proxy` | 80 | internal host-based router to the ota-lith ports |
| `caddy` | 80/443 | public TLS + login (only in the VPS deploy) |

Two separate auth planes, and they are easy to confuse: **humans** sign in to the console;
**tooling** (torizoncore-builder/garage-sign) uses a client-credentials token from our own endpoint,
because GitHub cannot serve that grant. Human login has three swappable front modes, all in Caddy so
the console stays user-agnostic: **none** (trusted LAN), **local users** (`AUTH_MODE=local`, the
`auth` sidecar — offline-capable, per-user, revocable), and **GitHub** (`GITHUB_CLIENT_ID`, via
oauth2-proxy). See [docs/console-auth.md](docs/console-auth.md) and
[docs/tooling-credentials.md](docs/tooling-credentials.md).

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
4. **The VPS runs a LOCAL `ota-lith` build, ahead of the registry — don't `docker compose pull` it.**
   It carries the non-AWS S3-endpoint patch **and** (since 2026-08-08) vendored ota-tuf at upstream
   master (SBOM, root.json fidelity). The published `samnite/ota-lith:0.2.0`/`:latest` have the S3
   patch but the OLDER ota-tuf, so pulling would quietly roll back the upgrade. Rebuild from source
   instead (Commands above). Rollback image on the VPS: `samnite/ota-lith:prerollback-otatuf` (and
   the older `:prerollback-s3`). Sanity-check a jar has the S3 patch with:
   `python3 -c "import zipfile;print(b'publicEndpointUrl' in zipfile.ZipFile('repo.jar').read('com/advancedtelematic/tuf/reposerver/target_store/S3TargetStoreEngine.class'))"`
5. **Single-file bind mounts pin the inode.** After editing `console/index.html` or an `nginx.conf`
   on the host, `docker restart` the container or it keeps serving the old file. Directory mounts
   (`console/js/`) pick changes up on their own.
6. **Two test devices; pick by what you're testing.** The **Verdin** (`ssh real-dev`, real ARM
   hardware) reports status to the cloud correctly — use it when the console must show the right
   device state. The **QEMU x86** (`ssh torizon-dev`, on the m920x host `claude@192.168.1.246`;
   boot it there with `kvm`+`docker` group access) is a disposable Docker-variant device that
   **installs updates fine but cannot report status** — its image is missing `/usr/bin/bl_actions.sh`
   so the bootloader secondary can't produce a manifest, and the device shows `Error`/stale in the
   console even after a successful install. Both are provisioned against the VPS.
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

**Run the smoke test before and after any change that could touch the core loop** (the stack,
storage, reposerver/director/provisioner/lockbox/ops/ras/auth, the console proxy, or a
compose/overlay change). `scripts/smoke-test.sh` brings up the plain LAN stack and, with no device
needed, checks provision → publish → read-back → lockbox, that **every console view is present in the
served `index.html`**, and — when the overlays are up — ops/System, ras, and the auth front:

```bash
UP=1 BASE=http://192.168.64.2:8080 bash scripts/smoke-test.sh                    # core + overlays
AUTH_BASE=https://ota.local ADMIN_USER=admin ADMIN_PASS=… USER_USER=stefano USER_PASS=… \
  bash scripts/smoke-test.sh   # + the auth front: gating, admin vs non-admin (run on the VM)
```

"Before" gives you a known-good baseline so you can tell what a failure actually means; skipping it
is how you end up unable to say whether *your* change broke something or it was already broken. This
is not optional ceremony — it exists because we shipped an opt-in that reasoned-correct but was never
run on the default path, and a `bootstrap.sh` that came up "healthy" with an uninitialised TUF repo.

**Verifying a deploy: check the served output changed, not just that it returns 200.** A UI change
was "deployed" but the browser still showed the old page — `console/js/*` (directory mount) was fresh
while `index.html` (single-file mount, rule 5) was a stale inode. `curl`-ing the asset returned 200
and misled me. After a UI change, `curl` the *page* and grep for the new element; after a service
change, exercise the actual behaviour. My own ad-hoc one-liners have been wrong more than once this
way — prefer the smoke test, and treat a hand-check that "passes" with suspicion until it's shown its
work.

**Device end-to-end** (provision → online docker-compose update → offline lockbox install) is done
manually today against the QEMU x86 — see [docs/architecture.md](docs/architecture.md) and the memory
notes. Scripting it as a repeatable rule is pending (offline updates now work via `torizoncore-builder
platform lockbox`, which the console's "Build bundle…" surfaces).
