# Roadmap

What is not done yet, and why it matters. Ordered roughly by value, not by effort.

## Near term

**Alerts.** Nothing tells you when something breaks — you find out by opening the console. The System
page already collects everything needed; what is missing is a threshold check plus a notifier
(ntfy/Telegram/email). Worth alerting on: a service down, disk above ~85%, and **certificate / TUF
root expiry** — the last one is the quiet killer, because expired metadata stops the whole fleet
updating and there is no warning until it happens.

**Backups of the unrecoverable state.** Some state cannot be regenerated:

| What | Why it is fatal to lose |
|---|---|
| `ras-data` | the RAS TUF + bastion keys |
| `ota-db` | device registrations, assignments, TUF role rows |
| `objects` / MinIO bucket | the target blobs themselves |

Losing the TUF signing keys means **re-provisioning every device in the fleet**. Everything else in
the stack can be rebuilt from the repo.

**A real test suite.** Currently verification is manual against the live instance and a device — good
for catching real breakage, bad for catching regressions. It should cover every component, not just
the console: the Uptane loop, provisioning, the sidecar APIs, the console modules, and ideally one
end-to-end device install. Several bugs found the hard way (ASCII metadata, gzipped TUF, stale
secondary stores) are exactly the kind a test suite would pin down permanently.

## Features

**Bundle container images into lockboxes.** The one gap left in offline updates. An offline install
currently gets as far as verifying the compose file and then fails with `Cannot load manifest with
digest …` — aktualizr does not use the local image cache, it loads the image *from the bundle* by
manifest digest. So `images/` has to carry the image content. Doable in pure Python by pulling
manifest + layers over the registry HTTP API (anonymous auth works for Docker Hub); no Docker socket
needed on the server. Until this lands, offline updates only work for devices that already have the
image.

**Fleet rollouts.** Updates are assigned per device. `campaigner` was removed rather than fixed; if
staged rollouts across many devices are wanted, this is where it returns — likely simpler to write
fresh against the director's assignment API than to revive it.

**Audit log.** Who provisioned, deployed, or opened a terminal, and when. The console can open a
root-ish shell on a device, so this matters as soon as more than one person has access.

**Fleet health view.** Last check-in per device, surfacing the ones that have gone quiet — a device
that stopped reporting is invisible in the current UI.

**Push device state to the console instead of polling (SSE).** Today the console re-fetches the
device list *and* one ECU call per device (`loadDevices()` in `console/js/views/devices.js`) on an
~8s timer, and — worse — it keeps polling on views that don't show devices and on a hidden/background
tab. That's an N+1 fetch on a fixed timer: fine for a handful of devices on one machine, but it does
not scale (100 devices ≈ 101 requests every 8s, forever). The proper fix is to **push**: ota-lith
already has a message bus that emits on device check-in / install-complete, and we already run SSE
plumbing (the `ops` log stream). A small sidecar subscribes to those events and streams device-state
changes to the console over SSE (`EventSource`), which updates reactively — no timer, no N+1.
Decided (2026-08-08) to go straight to this push model rather than the cheaper stops-gaps (poll only
when visible / pause on hidden tab / server-side aggregation endpoint), which stay as fallbacks if
SSE proves heavier than expected. Reuse the `ops` SSE + docker-socket-proxy pattern for shape.

## Operational debt

**~~Push the images to a registry.~~ Done — 0.3.0, 2026-08-08.** All **six** images
(`ota-lith`, `ota-ce-provisioner`, `ota-ce-lockbox`, `ota-ce-ops`, `ota-ce-auth`, `ras`) are published
multi-arch (amd64+arm64) as `0.3.0` and `latest`. 0.3.0 carries the ota-tuf-master upgrade, the
`/director` lockbox proxy, and the auth service (which had never been published). Built on the m920x
host.

Remaining: the VPS still *runs* a locally-built `ota-lith` (content-identical to `0.3.0`). Repointing
it at the registry (`OTA_CE_TAG=0.3.0`, `pull` + recreate + restart the nginx proxies) would make the
registry the source of truth and retire CLAUDE.md rule 4.

**Pin the MinIO image.** `compose.s3.yaml` uses `minio/minio:latest` while everything else is pinned
(`nginx:1.27`, `mariadb:10.11`). Pin it once a known-good release tag is confirmed.

**Consider upstreaming the reposerver patches.** The endpoint override and the S3-compatible signing
fixes are genuinely general — any self-hosted ota-tuf deployment hits them. The bearer-token
assumption in `garage-sign` (`AuthenticatedHttpBackend.scala`, which only skips auth for
`*.amazonaws.com`) is arguably an upstream bug worth reporting; we work around it in the proxy.

**Repo hygiene.** The work lives on `greenfield-boot-fixes`, well ahead of `v2`/`v3`. At some point:
decide the branch story, and whether the repo stays public.
