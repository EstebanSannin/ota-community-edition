#!/bin/bash
# ota-hwinfo — collect device hardware / OS / kernel / peripheral info into a JSON that
# aktualizr publishes as system_info (via --hwinfo-file). Writes /var/sota/hwinfo.json and
# restarts aktualizr only when the meaningful report (ota_report) changes, so a device
# hot-plug (USB), an OS update, etc. is reflected in the cloud without manual steps.
set -uo pipefail

OUT=/var/sota/hwinfo.json
TMP="$(mktemp)"; trap 'rm -f "$TMP"' EXIT

# --- collect (each field degrades gracefully if a tool/path is missing) ---
lshw_json=$(lshw -json 2>/dev/null || echo '{}')
kernel=$(uname -r); arch=$(uname -m)
kbuild=$(cat /proc/version 2>/dev/null || true)
cmdline=$(cat /proc/cmdline 2>/dev/null || true)
governor=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || true)
device_tree=$(cat /proc/device-tree/model 2>/dev/null | tr -d '\0' || true)   # ARM only; absent on x86
last_boot=$(uptime -s 2>/dev/null || true)
modules=$(lsmod 2>/dev/null | awk 'NR>1{print $1}' | paste -sd, -)
os_name=""; os_version=""; os_variant=""; os_id=""
if [ -r /etc/os-release ]; then . /etc/os-release; os_name=${NAME:-}; os_version=${VERSION:-}; os_variant=${VARIANT:-}; os_id=${ID:-}; fi
# NB: no `|| echo` inside these pipelines — under `set -o pipefail` a tool that both
# prints output and exits non-zero (e.g. lsusb with no devices on x86) would concatenate
# the fallback onto the real output, yielding two JSON values. Capture, then default if empty.
usb=$(lsusb 2>/dev/null | jq -R . | jq -s . 2>/dev/null); [ -n "$usb" ] || usb='[]'
block=$(lsblk -J -o NAME,SIZE,TYPE,FSTYPE,MODEL,TRAN,MOUNTPOINTS 2>/dev/null); [ -n "$block" ] || block='{"blockdevices":[]}'
# interfaces as objects {name,state,mac,ipv4} — ip -j gives structured output on modern iproute2.
# Skip virtual/ephemeral interfaces (docker veth/bridges, lo, tun/tap, uap, sit) — otherwise the
# report churns every time a container starts/stops and would trigger needless republishes.
nics=$(ip -j addr show 2>/dev/null | jq -c '[.[] | select((.ifname|test("^(lo|sit|docker|veth|br-|virbr|tap|tun|uap)"))|not) | {name:.ifname, state:.operstate, mac:(.address//null), ipv4:([.addr_info[]?|select(.family=="inet")|.local]|first//null)}]' 2>/dev/null); [ -n "$nics" ] || nics='[]'
# eMMC wear/health from sysfs (JEDEC eMMC 5.0: pre_eol_info + device life-time estimates).
# Only the whole-device nodes (mmcblkN) expose it — skip partitions / boot / rpmb. Raw hex
# values; the console decodes them. Empty on non-eMMC boards (e.g. virtio on QEMU).
storage_health=$(for d in /sys/class/block/mmcblk*; do
    n=${d##*/}
    [ -r "$d/device/life_time" ] || continue     # partitions/boot share device/, filtered next
    [ "$n" = "${n%%p[0-9]*}" ] || continue        # skip partitions (mmcblkNpM)
    [ "$n" = "${n%%boot*}" ]   || continue        # skip boot areas (mmcblkNbootM)
    [ "$n" = "${n%%rpmb*}" ]   || continue        # skip rpmb
    jq -n --arg dev "$n" \
      --arg life_time "$(cat "$d/device/life_time" 2>/dev/null)" \
      --arg pre_eol "$(cat "$d/device/pre_eol_info" 2>/dev/null)" \
      --arg model "$(cat "$d/device/name" 2>/dev/null)" \
      '{dev:$dev, life_time:$life_time, pre_eol:$pre_eol, model:$model}'
  done | jq -s . 2>/dev/null); [ -n "$storage_health" ] || storage_health='[]'

# --- assemble: the lshw tree + a clean top-level ota_report object ---
printf '%s' "$lshw_json" | jq \
  --arg kernel "$kernel" --arg arch "$arch" --arg kbuild "$kbuild" --arg cmdline "$cmdline" \
  --arg governor "$governor" --arg device_tree "$device_tree" --arg last_boot "$last_boot" \
  --arg modules "$modules" --arg os_name "$os_name" --arg os_version "$os_version" \
  --arg os_variant "$os_variant" --arg os_id "$os_id" \
  --argjson usb "$usb" --argjson block "$block" --argjson nics "$nics" \
  --argjson storage_health "$storage_health" \
  '(if type=="array" then (.[0] // {}) else . end) + {ota_report: {
      kernel:$kernel, arch:$arch, kernel_build:$kbuild, kernel_cmdline:$cmdline,
      cpu_governor:$governor, device_tree:$device_tree, last_boot:$last_boot,
      os_name:$os_name, os_version:$os_version, os_variant:$os_variant, os_id:$os_id,
      modules:(if $modules=="" then [] else ($modules|split(",")) end),
      usb:$usb, block_devices:($block.blockdevices // []), interfaces:$nics,
      storage_health:$storage_health
  }}' >"$TMP" || { echo "ota-hwinfo: jq assembly failed" >&2; exit 1; }

# --- keep the file current; NEVER restart aktualizr ---
# aktualizr reads --hwinfo-file only at startup, so it publishes this on its next natural start
# (a reboot — which every OS update does anyway). We deliberately do NOT restart aktualizr here:
# a restart mid-update kills it after the OSTree deploy but before it records the install, leaving
# the device in an inconsistent "storage vs OSTree mismatch" state. Freshness of system_info is
# not worth risking the update flow.
new=$(jq -cS '.ota_report' "$TMP" 2>/dev/null)
old=$(jq -cS '.ota_report' "$OUT" 2>/dev/null || echo "none")
if [ "$new" = "$old" ]; then
  echo "ota-hwinfo: no change"
  exit 0
fi
install -m600 "$TMP" "$OUT"
echo "ota-hwinfo: report changed — updated $OUT (aktualizr will publish it on its next start; not restarting)"
