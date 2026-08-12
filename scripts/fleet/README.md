# Virtual fleet — x86 QEMU Torizon devices

`fleet.sh` spins N throwaway x86 QEMU Torizon devices on this host and provisions them
against the OTA CE cloud (`ota.samnium.tech`). One pristine base image + thin per-VM overlays.

## Commands

| Command | QEMU | Local overlays | Cloud devices |
|---|---|---|---|
| `./fleet.sh golden`    | — (one-time build) | creates `golden.qcow2` | — |
| `./fleet.sh up`        | boot N VMs | created/reused | — |
| `./fleet.sh provision` | — | — | **registers** them |
| `./fleet.sh status`    | — | — | shows table |
| `./fleet.sh stop`      | power off | **kept** | untouched — `up` **resumes the same devices** |
| `./fleet.sh down`      | power off | **deleted** | left as-is (go stale; become orphans) |
| `./fleet.sh purge`     | power off | **deleted** | **deleted** too (clean slate) |
| `./fleet.sh ssh <n> [cmd]` | shell into VM n | | |

**Everyday pause/resume = `stop` then `up`** (no re-provisioning, no duplicate devices).
`down`/`purge` are teardown; only `purge` removes the cloud records.

## Config (env)

`FLEET_COUNT` (default 10) · `FLEET_RAM_MB` (512) · `FLEET_VCPUS` (1) · `OTA_URL` · `FLEET_TOKEN`
`FLEET_VPS_SSH` — ssh prefix so `purge` can delete cloud devices, e.g. `ssh root@ota.samnium.tech`.

## Provisioning token (required)

Enrollment is token-gated. Mint one on the VPS (TTL 1 h, reusable for all VMs):

```
ssh root@ota.samnium.tech 'curl -fsS -X POST http://localhost:8080/api/provision-tokens'
```

Then: `FLEET_TOKEN=<tok> ./fleet.sh provision` (or write it to `./token`).

## Notes

- Each VM registers as a **distinct** device (server-minted UUID + random ECU serials).
- Devices show **UpToDate** while idle. `bl_actions.sh` log noise on x86 is harmless (no u-boot).
- Layout: `base/` (read-only `.wic` + OVMF + `golden.qcow2`), `vms/` (per-VM overlays + markers).
