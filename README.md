# OTA Community Edition

A **super-simple, self-hostable OTA cloud** for embedded Linux devices — provision a device and
deploy over-the-air updates, using the open [TUF](https://theupdateframework.io/)/[Uptane](https://uptane.github.io/)
update framework. It bundles the Uptane service stack into a single container (`ota-lith`), adds a
clean web **console**, a **device gateway**, and **self-service provisioning**, and it works with
**external package sources** (TUF delegations) so devices can pull updates published — and hosted —
by third parties.

> This is a greenfield fork focused on being easy to run on one machine. It boots from a clean
> database, provisions real [Torizon OS](https://www.toradex.com/torizon) devices, and deploys both
> your own packages and delegated OSTree updates. See **[docs/status-report.md](docs/status-report.md)**
> for the full picture of what works.

## Quickstart

**Requirements:** Docker (with the `docker compose` plugin). To *build* the `ota-lith` image you
also need a JDK 21 + [sbt](https://www.scala-sbt.org/) (only for the first build).

```bash
./bootstrap.sh
```

That builds the image (if needed), generates certificates, starts the stack, and initializes the
TUF repository. When it finishes, open the console:

```
http://localhost:8080
```

Then **Provision device** → copy the one-liner → run it on your device → deploy an update. Stop the
stack with `docker compose -f ota-ce.yaml down` (add `-v` to also wipe the database).

## Provisioning a device

The console's **Provision device** button shows a Torizon-style one-liner to run on the device (as
root):

```bash
curl -fsSL http://<server>:8080/provision-device.sh | sudo bash -s -- -s http://<server>:8080 -n <name>
```

It fetches freshly-minted credentials from the cloud, points the device at your gateway, and starts
the update client. The device appears in the console within ~20 s. (For manual/scripted provisioning
without the console, see `scripts/gen-device.sh`.)

## Deploying software

- **Your own packages** — upload a binary version in the console (**Packages → Upload**), then
  **Deploy** it to a device.
- **External package sources** — add a TUF **delegation** (**Package Sources → Add source**) to
  trust a third-party feed. Its packages become browsable and deployable; devices pull the OSTree
  objects **directly from the publisher's store** (the URI in the delegation metadata), so you don't
  host or mirror them. This is verified end-to-end against Toradex's *Common Torizon Nightly* feed.

## What's inside

| Service | Role |
|---|---|
| `ota-lith` | The Uptane stack in one container: **reposerver** + **keyserver** (ota-tuf), **director** (with device-registry merged in), **treehub** |
| `gateway` | Device-facing mTLS endpoint; proxies director / repo / treehub / registration to the device |
| `reverse-proxy` | Host-based router for the `*.ota.ce` admin APIs |
| `console` | The web UI (static SPA + same-origin API proxy) |
| `provisioner` | Mints + registers device credentials on demand (serves `provision-device.sh`) |
| `db` | MariaDB (self-initializes the databases on first start) |

Ports: **8080** console · **80** admin APIs (`*.ota.ce`) · **30443** device gateway (mTLS) · **3306** MariaDB.

Configuration is a single file (`ota-lith-ce.conf`) — no sprawl of environment variables. Kafka is
optional (the default test message bus needs no Kafka); uncomment the services in `ota-ce.yaml` to
enable it.

## Advanced / manual use

The `*.ota.ce` hostnames are only needed for manual admin scripts (`get-credentials.sh`,
`gen-device.sh`) run from the host — add them to `/etc/hosts` pointing at `127.0.0.1`:

```
127.0.0.1 reposerver.ota.ce keyserver.ota.ce director.ota.ce treehub.ota.ce ota.ce
```

- Deploy via the API or [ota-cli](https://github.com/simao/ota-cli/): see
  [docs/api-updates.md](docs/api-updates.md) and [docs/updates-ota-cli.md](docs/updates-ota-cli.md).
- End-to-end test helpers (aktualizr build, provision/update/source scripts): see [test/](test/README.md).

## Dependency management

The Uptane services are vendored under `repos/` using
[git-subtree](https://man.archlinux.org/man/git-subtree.1). Upstream sources:

- ota-tuf (reposerver + keyserver) — https://github.com/uptane/ota-tuf
- director (device-registry is merged into it here) — https://github.com/uptane/director
- treehub — https://github.com/uptane/treehub
- libats — https://github.com/uptane/libats

To pull upstream changes, e.g.:

```bash
git subtree pull --prefix repos/ota-tuf git@github.com:uptane/ota-tuf.git master --squash
```

## Credits & upstream

The Uptane implementation is developed by the [Uptane contributors](https://github.com/uptane/).
OTA Community Edition was originally created by Advanced Telematic Systems (later HERE
Technologies); the single-container `ota-lith` packaging is by [simao](https://github.com/simao).
[Toradex](https://toradex.com) runs the same Uptane implementation as part of the
[Torizon platform](https://app.torizon.io). This fork builds on all of that work.

## Related

- https://github.com/uptane/ — upstream Uptane projects
- https://github.com/simao/ota-cli — command-line OTA client
- https://developer.toradex.com/torizon/ — Torizon platform docs
