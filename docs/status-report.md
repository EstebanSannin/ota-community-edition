# OTA Community Edition — greenfield bring-up status report

_Branch: `greenfield-boot-fixes` (forked from `v3`). Work done 2026-08 on a Debian
arm64 VM + MariaDB 10.11._

## Summary

Starting from `v3`, which **would not build or boot from a clean database**, this branch
brings the `ota-lith` monolith to a **working state on a fresh install** and proves the full
OTA loop end-to-end with a real `aktualizr` client: build → boot → provision a device →
upload a package → deploy an update → device installs and reports back. It also adds a
**minimal web console** and **external package sources (TUF delegations)**, verified against
Toradex's real "Common Torizon Nightly" feed.

## Goal

A super-simple, self-hostable OTA cloud that can **provision a device** and **perform an
update** — a cleaned-up, greenfield-friendly fork of the microservice-era community edition.

## Test environment

- Debian 13 (trixie), aarch64, 4 CPU / ~6 GB RAM.
- Docker + compose, Temurin JDK 21, sbt.
- One gotcha worth noting: the VM had a **Path-MTU blackhole** (1500-byte packets silently
  dropped to some CDNs), which looked like TLS errors and would have broken Docker pulls.
  Fixed by lowering the interface + Docker MTU to 1400.

## What was fixed (in order)

### 1. Build & boot (commit `52db2e3`)
- `build.sbt`: the hand-written Dockerfile used `ADD opt /opt`, incompatible with
  sbt-native-packager 1.9.16's **layered** build (content is staged under `2/opt`, `4/opt`).
  Replaced with the idiomatic base-image config + runtime-dir creation; the image run-user is
  `1001:0`, not the `daemon` the old file assumed.
- `build.sbt`: pre-create the treehub/reposerver local object-storage dirs (their
  `LocalFsBlobStore` requires the parent to exist and be writable).
- `ota-ce.yaml`: the `ota-lith` service used `build: .` but there is no root Dockerfile (sbt
  generates it). Point it at the built image instead.

### 2. Device-registry schema reconstruction (commit `52db2e3`)
The **core blocker**. device-registry was merged into the director at the *code* level, but its
schema-creating migrations were lost when the standalone service was removed. The director's
`V9`/`V10` only migrate an existing microservice `device_registry` database, so **fresh installs
crash on migration**. Upstream `uptane/director` is broken the same way, and
`uptane/ota-device-registry` is archived — so re-syncing wasn't an option.

Fix: materialized the device-registry schema from the archived upstream migrations
(**V1–V40**, incl. the hibernation table the director expects), folded it directly into
`director_v2` as a new `V9__create_device_registry_schema.sql`, and made `V10` a no-op. Result:
a fresh boot applies all director migrations with **0 failures**, and the device tables are
created + evolved correctly (verified: director's own V13 adds MQTT columns on top).

### 3. Provisioning wiring (commit `cde00aa`)
- `gateway.conf`: device-registry routes (`/system_info`, `/core`, `/events`) pointed at the
  dead standalone service on `:7500`; repointed to the director on `:7300` under
  `/device-registry/api/v1`.
- **Replaced Traefik with a plain nginx reverse-proxy** (`ota-ce/reverse-proxy.conf`): Traefik
  couldn't talk to Docker 29's API and 404'd everything; nginx has no such dependency and is a
  better fit for a single-container monolith.
- `ota-ce.yaml`: bumped the dead `nginx:1.13.7` gateway to `1.27`; fixed the `ota-lith`
  healthcheck (an unquotable `|| exit 1` kept it "unhealthy"); removed the legacy Quasar
  `web-ui` service (it no longer builds).
- `gen-device.sh`: register via `POST /device-registry/api/v1/devices` (was `PUT` to a dead
  host). `get-credentials.sh`: robust repo-id extraction.

### 4. End-to-end verification with aktualizr (commit `6c4cf3d`)
Built `aktualizr` from source and ran a real device against the stack. It provisions over the
gateway (mTLS), registers ECUs, and a pushed target + multi-target-update + assignment is
**downloaded, installed, and reported** — the director then shows the exact installed image,
across two successive versions, with device events recorded.
- `gen-device.sh`: copy `server_ca.pem` to `ca.pem` (a symlink to an absolute host path is
  dangling inside a container / on a real device, so cert import failed).
- `gateway.conf`: match `/events` without a trailing-slash 301 to the internal port; set
  `absolute_redirect off`.

## The minimal console (commits `abce982`, `bb8eb57`)

`console/` — a small self-contained SPA (nginx) that proxies the backend JSON APIs same-origin.
Wired into `ota-ce.yaml` as the `console` service on `:8080`. It can:
- List provisioned **devices** (status + installed image).
- List **software versions** and **upload** a new binary version.
- **Deploy** a version to a device (creates the MTU + assignment).
- Manage **package sources** (see below): add / list / refresh / remove, and browse packages.

## External package sources — TUF delegations (commit `bb8eb57`)

A Torizon Cloud "package source" is a **TUF remote trusted-delegation**, which the reposerver
fully supports. The Torizon `add-*.json` bundle maps 1:1 to three reposerver calls:
`PUT /trusted-delegations/keys`, `PUT /trusted-delegations`, `PUT /trusted-delegations/{name}/remote`.
Verified against the real **Common Torizon Nightly** feed: the reposerver fetched Toradex's
metadata, **verified its RSA-PSS signature**, and listed **578 packages** — browsable via the
console.

## Current status

| Capability | Status |
|---|---|
| Compiles (subtree-merged v3) | ✅ |
| arm64 Docker image builds | ✅ |
| Boots from a clean DB, all services healthy | ✅ |
| Device provisioning (gateway mTLS + ECU registration) | ✅ verified |
| Upload package + deploy update (binary) | ✅ verified (two versions) |
| Device downloads, installs, reports; director reflects state | ✅ verified |
| Web console (devices / versions / upload / deploy / sources) | ✅ |
| Add external package source (TUF delegation) + browse | ✅ verified (578 pkgs) |
| Deploy a **delegated OSTREE** package to a device | ⏳ not yet (see below) |

## Known limitations / next steps

- **Deploying delegated OSTREE packages** is not yet wired. These targets are `OSTREE` format
  with an external ostree URI; installing one needs a device whose hardware id matches (e.g.
  `intel-corei7-64`), an OSTREE-format update, and the ostree commit reachable by the device
  (either pulled from the external URI per the metadata, or mirrored into our treehub — to be
  determined by experiment).
- **Real-device experiment (planned):** boot a TorizonCore `intel-corei7-64` image in QEMU,
  provision it against this cloud, assign a delegated `intel-corei7-64` target, and observe the
  ostree pull. Note: the only QEMU-runnable feed target is x86, so on an arm64 host it runs
  under (slow) emulation.
- **Cleanup candidates:** remove the legacy `web-ui/` sources; refresh `docs/` that still
  reference the removed `campaigner` / `deviceregistry` hosts.

## Reproducing the end-to-end flow

See `test/` for the aktualizr build and the e2e helper scripts (provision, push-update, add
package source). High level, from the repo on the stack host:

```bash
sbt "Docker / publishLocal"                 # build the ota-lith image
scripts/gen-server-certs.sh                 # one-time server + device CA
docker compose -f ota-ce.yaml up -d db ota-lith reverse-proxy gateway console
scripts/get-credentials.sh                  # create TUF repo + credentials.zip
scripts/gen-device.sh                       # mint a device + register it
# build & run aktualizr (see test/aktualizr), then deploy from the console at :8080
```

## Branch & commits

`greenfield-boot-fixes` on the fork:
- `52db2e3` — fix fresh-install build & boot (Dockerfile, storage, schema reconstruction)
- `cde00aa` — wire up the device-facing provisioning path
- `6c4cf3d` — device cert import + event reporting (aktualizr-verified)
- `abce982` — minimal OTA console
- `bb8eb57` — console: package sources (TUF delegations)
