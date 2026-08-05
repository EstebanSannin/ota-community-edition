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
device_tree=$(tr -d '\0' </proc/device-tree/model 2>/dev/null || true)
last_boot=$(uptime -s 2>/dev/null || true)
modules=$(lsmod 2>/dev/null | awk 'NR>1{print $1}' | paste -sd, -)
os_name=""; os_version=""; os_variant=""; os_id=""
if [ -r /etc/os-release ]; then . /etc/os-release; os_name=${NAME:-}; os_version=${VERSION:-}; os_variant=${VARIANT:-}; os_id=${ID:-}; fi
usb=$(lsusb 2>/dev/null | jq -R . | jq -s . 2>/dev/null || echo '[]')
block=$(lsblk -J -o NAME,SIZE,TYPE,FSTYPE,MODEL,TRAN,MOUNTPOINTS 2>/dev/null || echo '{"blockdevices":[]}')
# interfaces as objects {name,state,mac,ipv4} — ip -j gives structured output on modern iproute2
nics=$(ip -j addr show 2>/dev/null | jq -c '[.[] | {name:.ifname, state:.operstate, mac:(.address//null), ipv4:([.addr_info[]?|select(.family=="inet")|.local]|first//null)}]' 2>/dev/null || echo '[]')
[ -n "$usb" ]   || usb='[]'
[ -n "$block" ] || block='{"blockdevices":[]}'
[ -n "$nics" ]  || nics='[]'

# --- assemble: the lshw tree + a clean top-level ota_report object ---
printf '%s' "$lshw_json" | jq \
  --arg kernel "$kernel" --arg arch "$arch" --arg kbuild "$kbuild" --arg cmdline "$cmdline" \
  --arg governor "$governor" --arg device_tree "$device_tree" --arg last_boot "$last_boot" \
  --arg modules "$modules" --arg os_name "$os_name" --arg os_version "$os_version" \
  --arg os_variant "$os_variant" --arg os_id "$os_id" \
  --argjson usb "$usb" --argjson block "$block" --argjson nics "$nics" \
  '(if type=="array" then (.[0] // {}) else . end) + {ota_report: {
      kernel:$kernel, arch:$arch, kernel_build:$kbuild, kernel_cmdline:$cmdline,
      cpu_governor:$governor, device_tree:$device_tree, last_boot:$last_boot,
      os_name:$os_name, os_version:$os_version, os_variant:$os_variant, os_id:$os_id,
      modules:(if $modules=="" then [] else ($modules|split(",")) end),
      usb:$usb, block_devices:($block.blockdevices // []), interfaces:$nics
  }}' >"$TMP" || { echo "ota-hwinfo: jq assembly failed" >&2; exit 1; }

# --- publish only when the meaningful report changed (avoids needless aktualizr restarts) ---
new=$(jq -cS '.ota_report' "$TMP" 2>/dev/null)
old=$(jq -cS '.ota_report' "$OUT" 2>/dev/null || echo "none")
if [ "$new" = "$old" ]; then
  echo "ota-hwinfo: no change"
  exit 0
fi
install -m600 "$TMP" "$OUT"
echo "ota-hwinfo: report changed — updated $OUT, restarting aktualizr"
systemctl restart aktualizr || true
