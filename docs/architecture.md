# Architecture, and why it looks like this

This explains how the pieces fit together and the reasoning behind the choices — the things you
cannot recover from reading the code. For day-to-day operations see
[operations.md](operations.md); for the historical bring-up record see
[status-report.md](status-report.md).

## The update loop, end to end

Everything else is scaffolding around this one path:

```
 operator                                  server                              device
 ────────                                  ──────                              ──────
 upload a package        ──▶  reposerver signs it into targets.json
 (console or TCB)                            │
                                             ▼
 deploy to a device      ──▶  director writes a per-device assignment
                                             │
                                             ▼
                              gateway (mTLS)  ◀──  aktualizr polls for metadata
                                             │      verifies signatures + hashes
                                             ▼
                              target bytes    ──▶  installs, reboots if needed,
                              (disk or MinIO)      reports the result back
```

Two TUF repositories are in play, and keeping them straight explains most of the codebase. The
**image repo** (reposerver) says "this package exists and here is its hash". The **director** says
"*this specific device* should install *that* package". A device verifies both, independently. That
is the Uptane design and it is why a single wrong byte anywhere fails the whole update rather than
degrading gracefully.

## Services

`ota-lith` is one JVM process hosting four upstream services on four ports (7100 reposerver, 7200
keyserver, 7300 director, 7400 treehub). Upstream ran these as separate deployments with Kafka
between them.

**Why a monolith:** the goal is one machine, one `docker compose up`. Separate services meant a
message bus, four sets of migrations and four failure modes to debug before the first device could
enrol. The monolith uses an in-process `LocalMessageBus` (`messaging.mode = "test"`) instead of
Kafka. The trade-off is real and accepted: services cannot scale independently, and the process is a
single blast radius. For a self-hosted fleet that is the right trade.

Two upstream components were removed rather than fixed:

- **`device-registry` is merged into the director**, served under `7300/device-registry/`. It was a
  thin CRUD service over device rows that the director already needed to join against.
- **`campaigner` is gone.** Fleet-wide campaign orchestration is a layer above single-device
  assignments; the console assigns updates directly. It can come back if fleet rollouts are wanted.

The sidecars exist because these jobs do not belong in the Uptane services at all, and each is
deliberately small enough to read in one sitting:

- **`provisioner`** — self-service enrolment. Serves a `provision-device.sh` one-liner and mints
  device credentials, so a board joins without the operator hand-copying certificates. Enrolment is
  gated by short-lived tokens, *not* the console login, so devices can enrol even if the login layer
  is down.
- **`ras`** — remote access: a reverse-SSH bastion plus an HTTP API, wire-compatible with Toradex's
  RAC client. Written in Rust because it needs a real SSH server. Powers the browser terminal.
- **`ops`** — the System page: container status, host/machine metrics, live logs. Reads Docker
  through a **read-only, GET-only socket proxy** so a bug in the log viewer can never stop a
  container. Samples in a background thread so the page paints instantly.
- **`lockbox`** — offline updates (`.zip` export), plus `credentials.zip` issuance and the tooling
  token endpoint.

Three fronts, because they have genuinely different threat models: the **gateway** speaks mTLS to
devices (client certificates, deny-by-default paths); the **console nginx** serves the SPA and
proxies its APIs same-origin; **Caddy** terminates public TLS and enforces the human login.

## Decisions worth knowing

**A console with no framework and no build step.** `console/` is static ES modules served by nginx —
no React, no bundler, no `node_modules`. The whole thing is inspectable with view-source and deploys
by copying files. The cost is no compiler to catch a bad import, which is exactly what
`scripts/check-console-modules.py` exists for; it is not optional, it is the type-checker. When the
single 1000-line file became hard to navigate it was split into one module per view, keeping the
no-build property.

**Sidecars are stdlib-only Python.** No Flask, no pip install, no dependency updates to track. Each
image is `python:3.12-slim` + `COPY`. For services that proxy some JSON and stream some logs, a
framework would be more code to audit, not less.

**Storage: local disk by default, S3/MinIO opt-in.** Local disk keeps the LAN case dependency-free,
but the reposerver's local backend refuses *out-of-band* uploads — which is exactly what
`torizoncore-builder platform push` does — so external tooling only works with S3. MinIO is an
overlay you opt into, not a required component. Two deliberate details:

- The upstream S3 code could only ever reach AWS (hardcoded region + dualstack, no endpoint
  override). We added `endpointUrl` and a *separate* `publicEndpointUrl` used only for signing
  upload URLs, so pre-signed URLs name a host external clients can reach. With both unset, AWS
  behaviour is byte-identical to upstream.
- **Devices never talk to the object store.** With a custom endpoint we *stream* target bytes back
  through the reposerver instead of redirecting to a pre-signed URL, which is what upstream does.
  Redirecting would force every device to reach MinIO and trust its certificate; streaming keeps the
  device path unchanged when storage changes underneath.

**Two auth planes, on purpose.** Humans authenticate with GitHub through oauth2-proxy. Tooling
cannot: `garage-sign` only speaks `client_credentials` (or mTLS), a grant GitHub and Google do not
offer. So the lockbox service runs a small token endpoint, and `/tuf/*` bypasses the browser login
with bearer auth. Device enrolment is a third path, token-gated, also outside the login. Collapsing
these would break one of the three.

**Offline updates are exported by us, not by torizoncore-builder.** The director already implements
the Lockbox roles (same code Torizon Cloud runs); what was missing was a way to get a bundle out.
Rather than require external tooling to download one, the `lockbox` service assembles the `.zip`
itself. A consequence worth remembering: compose files in a lockbox **must** pin images by digest,
and canonicalization has to happen *before* the file becomes a target — the exporter cannot rewrite
it at download time, because the bytes are hash-verified against signed metadata.

**`repos/` is vendored, not a submodule.** Upstream Scala lives in-tree and is patched when
necessary. Patches stay surgical and gate new behaviour behind config, so the upstream default path
is untouched — that is what makes the diff reviewable and rebasable.

## Sharp edges in the domain

These are properties of TUF/Uptane and Torizon, not bugs to fix:

- **Byte-exactness is absolute.** Metadata is pinned by hash *and* length. Compression, a re-encoded
  character, a proxy that rewrites a header — any of these fail the whole update. Most outages in
  this project have been some flavour of "something touched the bytes".
- **Metadata versions only go forward, and keys are pinned.** A device that talked to a different
  server keeps that server's root chain and will reject ours. Each *Secondary* keeps its own store,
  which is easy to forget when clearing device state.
- **Storage backends are not interchangeable at runtime.** Local disk and S3 use the same key layout,
  so migration is a copy — but switching without migrating silently 404s every existing target.
