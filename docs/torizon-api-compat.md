# Evaluation: a Torizon-compatible API for OTA Community Edition

_Status: **evaluation only** (not built). Scope of the question: could we expose an API server
compatible with the official [Torizon API 2.0](https://app.torizon.io/api/docs-2.0/), at least for
the features this CE already has?_

## Short answer

**Yes, for a meaningful subset — via a thin adapter service**, not by changing the Uptane
services. The Torizon API 2.0 is a stable, well-scoped REST surface (41 endpoints) that sits in
front of the same Uptane stack we vendor here. Roughly **half of it maps almost 1:1** onto our
existing reposerver / director / device-registry APIs; the rest depends on components this CE
doesn't include (remote access, metrics pipeline) or on concepts we only partially have
(fleets, lockboxes). Recommendation: **treat it as an opt-in adapter built in phases**, starting
with devices + packages + external sources + updates, which are the endpoints most tooling needs.

## Two cross-cutting differences to decide first

1. **Auth.** Torizon API uses `BearerAuth` (OAuth2 bearer tokens) and is **multi-tenant**
   (per-account repository). This CE runs **single-tenant** on namespace `default`, no auth. An
   adapter would either ignore/short-circuit auth (LAN/dev) or accept a static bearer token and map
   everything to the one namespace. No per-account isolation without real work.
2. **Fleets = a first-class concept.** Torizon "fleets" are device groups with hardware-id rollups.
   The merged device-registry has **device groups**, so fleets are *partially* backed, but the
   Torizon fleet semantics (update-to-fleet, hardware-id aggregation) need adapter logic.

## Endpoint mapping

| Torizon API 2.0 group | CE backing | Feasibility |
|---|---|---|
| `/devices`, `/devices/{uuid}`, `/name`, `/notes`, `/tags`, `/hibernation` | device-registry (list/get/create + those fields) | ✅ direct |
| `/devices/token` | our **provisioner** (`/api/provision` + token) | ✅ direct (already built) |
| `/devices/uptane/{uuid}/assignment`, `/components`, `/packages` | director (assignments, ECUs, installed images) | ✅ direct |
| `/packages`, `/packages/{id}` (upload/list/get/delete) | reposerver `user_repo/targets` | ✅ direct |
| `/packages_external`, `/info`, `/refresh/{name}` | reposerver **trusted-delegations** (already built) | ✅ direct — this is our external-sources feature |
| `/updates`, `/updates/{id}`, `/updates/devices/{id}` | director MTU + assignments | ✅ direct |
| `/fleets*` | device-registry **groups** | 🟡 partial — group CRUD maps; fleet-update semantics need adapter |
| `/lockboxes*`, `/lockbox-details` | offline-update / offline-signed roles (backend exists, not exposed) | 🟡 partial — needs wiring |
| `/device-data/*` (metrics, outliers, reports) | device-registry `device_monitoring` (code merged, not exposed) | 🟡 partial — fluent-bit pipeline not wired |
| `/devices/network*` | device network reporting | 🟡 partial |
| `/remote-access/*` (RAC sessions, SSH keys, IP allow-list) | — not in this stack | ❌ absent (separate Torizon component) |

Rough split: **~22 endpoints direct**, **~13 partial**, **~6 absent**.

## Suggested approach (if/when we pursue it)

A small **`torizon-api` adapter service** (same pattern as `provisioner`: a lightweight server on
the compose network) that:
- serves the Torizon 2.0 request/response schemas,
- translates each call into our internal reposerver/director/device-registry calls,
- maps the single `default` namespace and (optionally) checks a static bearer token.

**Phasing:**
1. **Phase 1 (highest value, all "direct" rows):** devices, packages, `packages_external`, updates,
   device assignment/components/token. This alone lets Torizon-oriented tooling and CI talk to the
   self-hosted cloud for the core provision + update flow.
2. **Phase 2:** fleets (over device groups) and lockboxes (offline updates).
3. **Phase 3 (only if needed):** device-data/metrics; remote-access is out of scope unless the RAC
   component is added.

**Effort:** Phase 1 is a contained adapter (schema mapping + passthrough), comparable in size to the
provisioner but broader. Phases 2–3 each add real backend wiring.

## Recommendation

Keep this **secondary**. The CE already delivers the end-to-end product via its own console + APIs.
Build the adapter only when there's a concrete need to reuse **existing Torizon tooling/clients**
against the self-hosted cloud — and then start with Phase 1, which is well within reach because the
underlying endpoints already exist and are proven here.
