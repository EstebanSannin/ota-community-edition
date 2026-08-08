# Offline updates (Lockbox)

An **offline update** — Torizon calls it a **Lockbox** — is a signed bundle of packages a device can
install with **no network**: you build it once, copy it onto removable media (or any local path), and
the device installs from there. It's the same workflow as Torizon Cloud, and it uses the standard
`torizoncore-builder` tool.

Requires a **Docker-variant** Torizon OS device (offline installs of docker-compose apps need Docker
on the device). The compose files in a lockbox must pin every image by **digest** (`image@sha256:…`)
— canonicalize them with `platform push --canonicalize` first (see
[tooling-credentials.md](tooling-credentials.md)).

## 1. Create the lockbox (console)

**Offline updates → New lockbox**: name it, pick the packages to include, create. This signs the
offline TUF roles on the server (the `offline-updates` + `offline-snapshot` roles in the director) —
it does **not** yet contain the container images. The list shows every lockbox with its packages and
expiry (default 365 days).

## 2. Build the removable-media bundle (`torizoncore-builder`)

The console's **Build bundle…** button shows the exact command. `torizoncore-builder` pulls the
container images and assembles the bundle, authenticating with your `credentials.zip` (from the
**Settings → Tooling credentials** — see [tooling-credentials.md](tooling-credentials.md)). In an empty
folder that contains `credentials.zip`:

```bash
docker run --rm -it \
  -v "$PWD":/workdir -w /workdir \
  -v /deploy -v /var/run/docker.sock:/var/run/docker.sock \
  torizon/torizoncore-builder:3 \
  platform lockbox <name> \
    --credentials credentials.zip \
    --output-directory <name>-lockbox \
    --platform linux/amd64          # linux/arm64 for a Verdin / ARM board
```

The `-v /var/run/docker.sock` mount is required — TCB runs Docker-in-Docker to pull the images. The
result, `<name>-lockbox/`, contains `metadata/` (signed director + image-repo roles) and `images/`
(the compose targets **and** the container image tarballs).

> This works against a self-hosted instance because the lockbox service proxies both `/tuf`
> (reposerver) and `/director` under the credentials.zip bearer — the two endpoints
> `platform lockbox` needs. (There is no server-side `.zip` export; TCB builds the real bundle,
> images included.)

## 3. Copy it to the device

Put the `<name>-lockbox` folder on the device's offline-update media (USB stick, or any path the
device can read), e.g. `/media/usb/<name>-lockbox`.

## 4. Enable offline updates on the device (once)

```toml
# /etc/sota/conf.d/99-offline-updates.toml
[uptane]
enable_offline_updates = true
offline_updates_source = "/media/usb/<name>-lockbox"
```

```bash
sudo systemctl restart aktualizr-torizon    # logs "Offline Updates are enabled"
```

## 5. Trigger the install

**The trigger is D-Bus, not file presence** — dropping the bundle in place does nothing on its own;
aktualizr does not poll for it, and does not fall back to offline when the server is unreachable.
Fire it:

```bash
sudo busctl call org.uptane.Aktualizr /org/uptane/aktualizr \
  org.uptane.Aktualizr OfflineUpdate s "/media/usb/<name>-lockbox"
```

(Introspect the interface with `busctl introspect org.uptane.Aktualizr /org/uptane/aktualizr` — it
also exposes `CheckForUpdates`, `Cancel`, `Consent`, and `InstallUpdatesAutomatically`.)

## 6. Verify

`journalctl -u aktualizr-torizon` should show the metadata verify, the image load **from the
bundle**, and success:

```
docker-compose file matches expected digest
Loading images from tarball: .../<image-digest>.tar
Loaded image: <repo>:digest_sha256_<hex>
Event: InstallTargetComplete, Result - Success
Event: AllInstallsComplete, Result - OK
```

The app's containers should then be running (`docker ps`).

## Troubleshooting

| Symptom | Cause |
|---|---|
| `Image name '…' not specified by digest` | the compose uses a tag, not `@sha256:…` — canonicalize it first |
| `Cannot load manifest with digest …` | the bundle lacks the image — rebuild with `platform lockbox` (not an old metadata-only export) |
| `platform lockbox` fails at auth / `404` | stale `credentials.zip`, or the `/director` proxy isn't reachable (self-hosted instance) |
| trigger does nothing | it must be the **D-Bus** call above; the device also needs `enable_offline_updates = true` |
| `docker compose … failed` on install | device Docker issue (e.g. a stuck old container) — not the bundle; clear it and retry |

See [architecture.md](architecture.md) for how the offline roles fit the two-TUF-repo model, and
[operations.md](operations.md) for the `lockbox` service.
