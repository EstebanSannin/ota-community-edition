# Upstream divergence: where `repos/` stands against uptane/*

## Update log

- **2026-08-08 — ota-tuf updated to upstream master (`8a0cb2b2`).** `git subtree pull` merged cleanly
  with a single conflict in `S3TargetStoreEngine.scala`, resolved by combining our endpoint/signing
  patch with upstream's new `DefaultAWSCredentialsProviderChain` (IRSA) support (the unused
  `CannedAccessControlList` import was dropped). Validated before deploy — isolated containerized
  build on a spare host: compiles, `ota-lith` boots healthy (all migrations incl. the new **V21
  SBOM** apply), and an S3 round-trip through MinIO returns byte-identically. Then deployed to the
  VPS and reverified: smoke test 15/15, pre-existing S3 targets read back, and a real Verdin device
  installed an update (`Success`). **Gains:** SBOM support, the `n.root.json` `JsonSignedPayload`
  byte-fidelity fix, and IRSA/instance-profile credentials. treehub was already current; director
  was left as-is (pure scalafmt churn, no functional gain, and it carries the V9-migration trap).
  Rollback image on the VPS: `samnite/ota-lith:prerollback-otatuf`.

Original analysis date **2026-08-07**, against `master` of each upstream repo.

`repos/` was vendored with `git subtree`, so every import recorded the exact upstream commit in a
`git-subtree-split` trailer. That makes the base identifiable with certainty rather than by guesswork
— all three were imported on **2026-01-07**.

## Summary table

| Project | Our base | Upstream `master` (2026-08) | Behind by | Our local changes | Effort to update |
|---|---|---|---|---|---|
| **treehub** | `ba09f983` | `ba09f983` | **0 commits** | **none** | **zero — already identical** |
| **director** | `855edc95` | `e43319c8` | 52 commits | 3 migration files | low, but **no functional gain** |
| **ota-tuf** | ~~`0f49b4f8`~~ **now `8a0cb2b2` (master, updated 2026-08-08)** | `8a0cb2b2` | **0 (current)** | S3 patch (re-applied on master) | done |

The headline: **our divergence from upstream is tiny** — six files across three projects. The
interesting drift is all in ota-tuf.

## treehub — nothing to do

Our copy is byte-identical to upstream `master`, and upstream has made no commits since our import.
There are **zero local modifications**. Whatever we do with the other two, treehub is a clean
pass-through.

## director — 52 commits, but effectively no functional change

Breaking the 52 commits down: ~25 are Scala Steward dependency bumps, and **one commit is a
repo-wide `scalafmt 3.10.5` reformat touching 49 files (+553/−255)**. That reformat plus the bumps
accounts for essentially all of the 54 changed files. There are **no upstream functional changes and
no new migrations** since our base.

So updating director buys us nothing today, and costs a large formatting-only diff.

### Our local change: the fresh-install migration fix

| File | State |
|---|---|
| `V9__use-dev-registry-views.sql` | **deleted by us** (upstream still ships it) |
| `V9__create_device_registry_schema.sql` | **added by us** (186 lines) |
| `V10__import-device-registry-data.sql` | **trimmed by us** (105 lines → mostly removed) |

Upstream's V9/V10 assume you are migrating an *existing* deployment that already has a separate
`device_registry` database: V9 creates views onto it and V10 imports its rows. On a greenfield
install that database does not exist, so boot fails. Ours creates the schema outright.

**This divergence is permanent and intentional** — upstream has no reason to support the greenfield
case, and this is precisely the fork's purpose.

> ### ⚠ Top migration risk: Flyway duplicate version
> A naive `git subtree pull` for director **restores upstream's `V9__use-dev-registry-views.sql`
> while ours stays in place**. Two migrations then declare version 9, and Flyway refuses to start
> ("found more than one migration with version 9"). Every future director update must delete
> upstream's V9 file again. Worth encoding as a check in CI, not a thing to remember.
>
> Related: because our V9 has a different filename and checksum from upstream's, **any existing
> database cannot later be switched to upstream's migration set** without editing
> `flyway_schema_history` by hand.

## ota-tuf — 191 commits, and the only one with real change

~85 are dependency bumps; one is a `scalafmt 3.11.1` reformat (13 files, +339/−197). The substantive
upstream work:

| Change | Relevance to us |
|---|---|
| **SBOM support** — new resource, `hasSBOM` search param, migration `V21__add_sboms.sql` | New feature; additive. The migration applies automatically and is one-way |
| **`DefaultAWSCredentialsProviderChain` fallback** when no explicit S3 keys (+ `aws-java-sdk-sts`) | Touches the exact constructor our patch rewrites → **merge conflict** |
| **Removed the canned ACL** (`AuthenticatedRead`) on S3 uploads | Mildly *helpful* to us — canned ACLs are an AWS-ism that S3-compatible stores handle inconsistently |
| `n.root.json` now returns a `JsonSignedPayload` (OTA-3305) | Wire-compatible (`{signatures, signed}` either way). Preserves the *original* signed bytes instead of re-encoding, so it should **improve** byte-fidelity — which is exactly the class of bug that has bitten us most |
| Return unsigned targets metadata when signing keys are offline; refactor of metadata-to-sign | Only affects offline-key setups; our keys are online |
| Delegation friendly-name on refresh; canonicalization tests; `Thread.sleep` removal | Neutral |

### Our local changes (all from the MinIO/out-of-band work)

| File | Change |
|---|---|
| `reposerver/.../target_store/S3TargetStoreEngine.scala` | +118/−… — custom endpoint (path-style, no dualstack), a separate signing client, stream-instead-of-redirect on `retrieve`, and don't sign extra headers on non-AWS stores |
| `reposerver/.../Boot.scala` | read the two new optional settings |
| `reposerver/src/main/resources/application.conf` | declare `endpointUrl` / `publicEndpointUrl` |

**Is any of it now upstream? No.** Upstream `master` still builds its S3 client with
`withRegion(...)` + `withDualstackEnabled(true)` and has **no endpoint override**, so a
self-hosted S3-compatible store remains unreachable there. Likewise `LocalTargetStoreEngine` still
raises `notSupportedForLocalStorageError` for all four out-of-band operations, so local-disk storage
still cannot serve `platform push`. And the CLI still withholds its bearer token only for
`*.amazonaws.com` (`AuthenticatedHttpBackend.scala`), so the workaround in our proxy is still
required.

**Every one of our patches is still necessary.** None can be dropped by moving to upstream.

## Build compatibility

- Both projects remain on **Scala 2.13.16** — same as our root `build.sbt`. No language-level break.
- Upstream bumped `sbt.version` 1.12.0 → **1.12.14**; our root build uses **1.9.9**. The root build's
  version wins for `ProjectRef` aggregation, which is why our builds work today, but this is a
  divergence to watch: if upstream starts using sbt-1.12-only plugin features, our root pins will
  need raising.

## Effort estimate

| Project | Effort | Worth doing? |
|---|---|---|
| treehub | none | already current |
| director | ~1h (mostly reviewing a formatting diff) + the V9 trap | **not now** — zero functional gain |
| ota-tuf | ~half a day: re-apply the ~120-line S3 patch onto reformatted code, absorb V21, then re-verify a device install and a TCB push | **yes, eventually** — for SBOMs and the root.json byte-fidelity fix |

## A structural option for the new repository

Our ota-tuf patch exists only because `S3TargetStoreEngine` is not configurable enough. But it *is*
an ordinary class, and `TufReposerverRoutes` takes the target store as a **constructor parameter** —
and we already own the boot path (`OtaLithCombinedBoot`). So it may be possible to keep our storage
engine as a **subclass in our own source tree** and wire it in ourselves, leaving `repos/ota-tuf`
completely unpatched. That would reduce the vendored diff to zero for ota-tuf and make future
updates a plain subtree pull.

This needs verifying against the reposerver boot wiring before committing to it — the engine is
selected inside the reposerver's own `Boot`, so how much of that we would have to reimplement is the
open question. The director migration divergence has no equivalent escape: those SQL files must live
where Flyway scans, though a custom Flyway location is worth investigating.

## Reproducing this analysis

The upstream refs were fetched into a private namespace so the repo's own remotes stay untouched:

```bash
for p in ota-tuf director treehub; do
  git fetch "https://github.com/uptane/$p.git" \
    "+refs/heads/*:refs/upstream/$p/heads/*" "+refs/tags/*:refs/upstream/$p/tags/*"
done

# our local changes on top of the vendored base
git diff --stat 0f49b4f8 HEAD:repos/ota-tuf
# what upstream did since
git log --oneline 0f49b4f8..refs/upstream/ota-tuf/heads/master
```

Remove them with `git for-each-ref --format='%(refname)' refs/upstream | xargs -n1 git update-ref -d`.
