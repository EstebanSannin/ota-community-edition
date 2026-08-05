# Device reporter (`ota-hwinfo`)

Adds the device-side data the cloud can't derive on its own — **kernel version + build, arch,
loaded modules, device tree, CPU governor, OS release, last boot, and live USB/block/network
peripherals** — by writing `/var/sota/hwinfo.json` and having aktualizr publish it as
`system_info` (`--hwinfo-file`). Re-runs on a 5-minute timer and on USB hot-plug (udev), and
restarts aktualizr only when the report actually changes.

## Why
aktualizr's default `system_info` is a one-time `lshw` dump (sent once, never re-sent). This
reporter fills the gaps and keeps them fresh. Live *runtime metrics* (RAM/CPU load) are out of
scope here — those belong in a metrics stream (e.g. fluent-bit).

## Install (on the device, as root)
```bash
sudo ./install.sh
```
Installs the script to `/var/lib/ota-hwinfo/`, a systemd `.service`+`.timer`, a udev rule, and an
aktualizr drop-in — all under writable `/var` and `/etc`.

## Files
- `ota-hwinfo.sh` — collector; writes `/var/sota/hwinfo.json`, restarts aktualizr on change.
- `ota-hwinfo.service` / `.timer` — periodic refresh.
- `99-ota-hwinfo.rules` — refresh on USB add/remove.
- `aktualizr-hwinfo.conf` — aktualizr drop-in enabling `--hwinfo-file`.

The enriched data lands under `system_info.ota_report` in the cloud.
