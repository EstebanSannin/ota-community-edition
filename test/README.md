# End-to-end test / reproducibility helpers

Helper scripts used to bring up and verify the full OTA loop during the greenfield
bring-up (see `docs/status-report.md`). They assume the stack is already running on
the host you execute them from:

```bash
sbt "Docker / publishLocal"
scripts/gen-server-certs.sh
docker compose -f ota-ce.yaml up -d db ota-lith reverse-proxy gateway console
```

and that `*.ota.ce` resolve to localhost (add to `/etc/hosts`):

```
127.0.0.1 reposerver.ota.ce keyserver.ota.ce director.ota.ce treehub.ota.ce ota.ce
```

## `aktualizr/Dockerfile`

Builds the `aktualizr` Uptane client from source (Debian trixie). Used as the test
"device". Build and run against the gateway:

```bash
docker build -t aktualizr:local test/aktualizr
# after scripts/gen-device.sh creates ota-ce-gen/devices/<uuid>/ :
docker run --rm --add-host ota.ce:host-gateway \
  -v "$PWD/ota-ce-gen/devices/<uuid>:/device" \
  aktualizr:local --run-mode=once --config=/device/config.toml
```

## `e2e/provision-device.sh`

Runs aktualizr once against the gateway (mTLS) to provision the most-recently-generated
device, then checks the director for the registered ECUs and device status.

## `e2e/push-update.sh`

Uploads a binary target to the reposerver, creates a multi-target update, and assigns it
to the device. `VER=0.0.2 bash e2e/push-update.sh` to bump the version. After running,
execute aktualizr again to install it.

Key API notes:
- `POST /api/v1/multi_target_updates` returns the MTU id.
- `POST /api/v1/assignments` needs **both** `correlationId` (`urn:here-ota:mtu:<uuid>`)
  and `mtuId` (raw uuid), plus `devices`.
- The director TUF repo must exist first (`POST /api/v1/admin/repo`), else the device
  gets `root_role_not_found`.

## `e2e/add-package-source.sh`

Registers an external package source (TUF remote delegation) from a Torizon-style
`add-*.json` bundle (`/tmp/addsrc.json`): the two RSA public keys, the delegation role,
and the fetch URL. Maps to `PUT /trusted-delegations/keys`,
`PUT /trusted-delegations`, `PUT /trusted-delegations/{name}/remote`. List delegated
packages with `GET /api/v1/user_repo/delegations_items[?nameContains=]`.

## `e2e/materialize-device-registry-schema.sh`

Regenerates the consolidated device-registry schema by replaying the archived upstream
migrations V1–V40 into a scratch DB and dumping the result — the source of
`repos/director/.../V9__create_device_registry_schema.sql`. Only needed if that schema
must be regenerated from upstream.

> These are pragmatic bring-up helpers, not a polished test suite — paths and the
> MariaDB container name (`ota-community-edition-db-1`) are assumed from the default
> `docker compose` setup.
