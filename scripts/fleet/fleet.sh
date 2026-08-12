#!/usr/bin/env bash
# fleet.sh -- spin a virtual fleet of Torizon x86 QEMU devices and provision them
#             against the self-hosted OTA CE cloud.
#
# Design: one pristine factory image (raw .wic) is the read-only root. A one-time
# "golden" overlay adds SSH-key access + passwordless sudo (Torizon ships with an
# expired password that blocks non-interactive login). Every VM is then a thin
# qcow2 overlay of the golden image, so a fresh VM starts from a clean /var/sota
# (no stale TUF store -> no "incorrect associated key ID"; see project rule 7).
#
# Usage:
#   fleet.sh golden                 one-time: build the golden image
#   fleet.sh up                     create overlays + boot COUNT VMs (detached)
#   fleet.sh provision              SSH into each VM, run the provisioning one-liner
#   fleet.sh status                 show per-VM running / ssh / provisioned state
#   fleet.sh stop                   power off VMs, KEEP overlays -> 'up' resumes SAME devices
#   fleet.sh down                   power off + delete overlays (cloud devices left as-is)
#   fleet.sh purge                  down + also DELETE the devices from the cloud
#   fleet.sh ssh <n> [cmd...]       SSH into VM n (debug helper)
#   fleet.sh console <n>            attach to VM n serial console (Ctrl-] to quit)
#
# stop/up is the everyday pause/resume (no re-provisioning, no duplicate devices).
# down/purge are teardown: 'down' leaves cloud records (they go stale), 'purge' removes them.
#
# Config via env: FLEET_COUNT, FLEET_RAM_MB, FLEET_VCPUS, OTA_URL, FLEET_TOKEN,
#   FLEET_VPS_SSH (ssh prefix to reach the VPS for 'purge', e.g. "ssh root@ota.samnium.tech").
set -euo pipefail

# --------------------------------------------------------------------------- config
FLEET_DIR="${FLEET_DIR:-/home/claude/fleet}"
BASE_DIR="$FLEET_DIR/base"
VMS_DIR="$FLEET_DIR/vms"

WIC="$BASE_DIR/torizon-base.wic"        # pristine raw factory image (read-only)
OVMF_CODE="$BASE_DIR/ovmf.code.qcow2"   # UEFI firmware code (read-only, shared)
OVMF_VARS="$BASE_DIR/ovmf.vars.qcow2"   # UEFI vars template (copied per VM)
GOLDEN="$BASE_DIR/golden.qcow2"         # wic + first-boot setup (read-only once built)

COUNT="${FLEET_COUNT:-10}"
RAM_MB="${FLEET_RAM_MB:-512}"
VCPUS="${FLEET_VCPUS:-1}"
SSH_PORT_BASE="${FLEET_SSH_PORT_BASE:-2220}"   # VM n -> host 127.0.0.1:(BASE+n)
MAC_PREFIX="52:54:00:12:34:"                   # + n as hex byte
SSH_KEY="${FLEET_SSH_KEY:-$HOME/.ssh/fleet_key}"
GUEST_USER="torizon"
GUEST_PW="Fleetota2026!"                        # set during golden first-boot

OTA_URL="${OTA_URL:-https://ota.samnium.tech}"
TOKEN="${FLEET_TOKEN:-$( [ -f "$FLEET_DIR/token" ] && cat "$FLEET_DIR/token" || true )}"
DEVICE_PREFIX="${FLEET_DEVICE_PREFIX:-fleet}"   # device names: fleet-01 ..
# 'purge' deletes cloud devices via this ssh prefix, curling the VPS-internal API.
VPS_SSH="${FLEET_VPS_SSH:-}"                     # e.g. "ssh -i ~/.ssh/k root@ota.samnium.tech"
DR_API="${FLEET_DR_API:-http://localhost:8080/api/device-registry}"  # base, as seen ON the VPS

SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
          -o LogLevel=ERROR -o ConnectTimeout=8 -o BatchMode=yes -i "$SSH_KEY")

# --------------------------------------------------------------------------- helpers
c_blue=$'\033[1;34m'; c_grn=$'\033[1;32m'; c_red=$'\033[1;31m'; c_yel=$'\033[1;33m'; c_off=$'\033[0m'
log(){ printf '%s[fleet]%s %s\n' "$c_blue" "$c_off" "$*"; }
ok(){  printf '%s[fleet]%s %s\n' "$c_grn"  "$c_off" "$*"; }
warn(){ printf '%s[fleet]%s %s\n' "$c_yel" "$c_off" "$*" >&2; }
die(){ printf '%s[fleet] ERROR:%s %s\n' "$c_red" "$c_off" "$*" >&2; exit 1; }

name(){ printf 'vm%02d' "$1"; }
port(){ echo $(( SSH_PORT_BASE + $1 )); }
mac(){  printf '%s%02x' "$MAC_PREFIX" "$1"; }
disk(){ echo "$VMS_DIR/$(name "$1").qcow2"; }
vars(){ echo "$VMS_DIR/$(name "$1")-ovmf.vars.qcow2"; }
con(){  echo "$VMS_DIR/$(name "$1").console"; }
qmp(){  echo "$VMS_DIR/$(name "$1").qmp"; }
devname(){ printf '%s-%02d' "$DEVICE_PREFIX" "$1"; }
running(){ pgrep -f "qemu-system.*$(disk "$1")\b" >/dev/null 2>&1; }

# Boot one VM detached. $1=index $2=backing disk $3=backing format (qcow2|raw)
boot_vm(){
  local idx="$1" backing="$2" fmt="$3" d v
  d="$(disk "$idx")"; v="$(vars "$idx")"
  mkdir -p "$VMS_DIR"
  [ -f "$d" ] || qemu-img create -f qcow2 -F "$fmt" -b "$backing" "$d" >/dev/null
  cp -f "$OVMF_VARS" "$v"; chmod 644 "$v" "$d"
  rm -f "$(con "$idx")" "$(qmp "$idx")"
  # setsid detaches into a new session so it survives our SSH logout.
  setsid bash -c "exec qemu-system-x86_64 \
    -name $(name "$idx") \
    -enable-kvm -m $RAM_MB -smp $VCPUS -cpu host -machine q35 \
    -drive if=pflash,format=qcow2,readonly=on,file=$OVMF_CODE \
    -drive if=pflash,format=qcow2,file=$v \
    -drive file=$d,if=virtio,format=qcow2 \
    -netdev user,id=n0,hostfwd=tcp:127.0.0.1:$(port "$idx")-:22 \
    -device virtio-net-pci,netdev=n0,mac=$(mac "$idx") \
    -display none \
    -chardev socket,id=con0,path=$(con "$idx"),server=on,wait=off \
    -serial chardev:con0 \
    -qmp unix:$(qmp "$idx"),server,nowait" \
    </dev/null >"$VMS_DIR/$(name "$idx")-qemu.log" 2>&1 &
  disown 2>/dev/null || true
}

gssh(){ local idx="$1"; shift; ssh "${SSH_OPTS[@]}" -p "$(port "$idx")" "$GUEST_USER@127.0.0.1" "$@"; }
wait_ssh(){  # wait until VM $1 accepts key-based SSH (timeout $2s, default 180)
  local idx="$1" t="${2:-180}" end; end=$(( $(date +%s) + t ))
  while [ "$(date +%s)" -lt "$end" ]; do
    gssh "$idx" true 2>/dev/null && return 0
    sleep 4
  done
  return 1
}

# --------------------------------------------------------------------------- golden
# Drive the serial console once: log in with the default expired password, change
# it, inject the fleet SSH key, enable passwordless sudo, then scrub per-machine
# identity so each overlay regenerates its own.
write_console_driver(){
  cat > "$FLEET_DIR/.console-drive.py" <<'PY'
import socket, sys, time, re
SOCK, PUB, DEFPW, NEWPW = sys.argv[1], sys.argv[2], "torizon", sys.argv[3]
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM); s.connect(SOCK); s.settimeout(1.0)
def expect(pats, timeout=60):
    buf=""; end=time.time()+timeout
    while time.time()<end:
        try: d=s.recv(4096)
        except socket.timeout: d=b""
        if d:
            buf+=d.decode("utf-8","replace")
            for p in pats:
                if re.search(p,buf): return p,buf
    return None,buf
def send(x): s.sendall((x+"\n").encode()); time.sleep(0.4)
send("")                                   # nudge
p,_=expect([r"login:", r"[\$#] $"], 90)
if p and "login" in p:
    send("torizon")
    expect([r"[Pp]assword:"],30); send(DEFPW)
    p,_=expect([r"[Cc]urrent.*password:", r"[\$#] $"],30)
    if p and "urrent" in p:                # forced first-boot change
        send(DEFPW)
        expect([r"[Nn]ew password:"],20); send(NEWPW)
        expect([r"[Rr]etype|new password:"],20); send(NEWPW)
        expect([r"[\$#] $", r"successfully"],30)
send("echo READY_$(id -un)")
expect([r"READY_torizon"],30)
send("mkdir -p ~/.ssh && chmod 700 ~/.ssh")
send("grep -qF '%s' ~/.ssh/authorized_keys 2>/dev/null || echo '%s' >> ~/.ssh/authorized_keys" % (PUB,PUB))
send("chmod 600 ~/.ssh/authorized_keys && echo KEYS_DONE")
expect([r"KEYS_DONE"],20)
send("echo '%s' | sudo -S sh -c 'echo \"torizon ALL=(ALL) NOPASSWD:ALL\" >/etc/sudoers.d/90-fleet; chmod 440 /etc/sudoers.d/90-fleet' 2>/dev/null" % NEWPW)
send("sudo -n true && echo SUDO_OK")
p,_=expect([r"SUDO_OK"],25)
print("SUDO_OK" if p else "SUDO_FAIL")
# scrub identity so each overlay is unique on next boot
send("sudo -n sh -c 'truncate -s0 /etc/machine-id; rm -f /var/lib/dbus/machine-id; rm -f /etc/ssh/ssh_host_*'")
send("sync && echo SCRUB_DONE")
expect([r"SCRUB_DONE"],20)
print("DRIVER_DONE")
s.close()
PY
}

cmd_golden(){
  [ -f "$WIC" ] || die "missing base image: $WIC"
  [ -f "$SSH_KEY.pub" ] || die "missing SSH key: $SSH_KEY.pub (ssh-keygen -f $SSH_KEY)"
  if [ -f "$GOLDEN" ]; then warn "golden already exists ($GOLDEN); remove it to rebuild"; return 0; fi
  chmod 444 "$WIC" "$OVMF_CODE" "$OVMF_VARS" 2>/dev/null || true
  write_console_driver
  log "building golden image (first-boot setup over serial console)..."
  # index 0 is the golden-build slot; boots directly off the raw wic
  boot_vm 0 "$WIC" raw
  sleep 3
  running 0 || { cat "$VMS_DIR/$(name 0)-qemu.log"; die "golden VM failed to start"; }
  # wait for the console socket
  local end; end=$(( $(date +%s) + 30 ))
  while [ ! -S "$(con 0)" ] && [ "$(date +%s)" -lt "$end" ]; do sleep 1; done
  [ -S "$(con 0)" ] || die "console socket never appeared"
  log "driving first-boot console (login -> passwd change -> key + sudo)..."
  local out; out=$(python3 "$FLEET_DIR/.console-drive.py" "$(con 0)" "$(cat "$SSH_KEY.pub")" "$GUEST_PW")
  echo "$out" | sed 's/^/    /'
  echo "$out" | grep -q DRIVER_DONE || die "console driver did not complete"
  log "verifying key-based SSH into golden VM..."
  wait_ssh 0 90 || die "key SSH into golden VM failed"
  ok "golden setup verified over SSH"
  log "powering off golden VM and sealing image..."
  gssh 0 "sudo -n poweroff" 2>/dev/null || true
  end=$(( $(date +%s) + 40 ))
  while running 0 && [ "$(date +%s)" -lt "$end" ]; do sleep 2; done
  running 0 && { pkill -f "qemu-system.*$(disk 0)"; sleep 2; }
  mv "$(disk 0)" "$GOLDEN"
  chmod 444 "$GOLDEN"
  rm -f "$(vars 0)" "$(con 0)" "$(qmp 0)" "$VMS_DIR/$(name 0)-qemu.log"
  ok "golden image ready: $GOLDEN"
}

# --------------------------------------------------------------------------- up
cmd_up(){
  [ -f "$GOLDEN" ] || die "no golden image; run: $0 golden"
  log "booting $COUNT VMs (${RAM_MB}MB / ${VCPUS} vCPU each) off golden..."
  local i
  for i in $(seq 1 "$COUNT"); do
    if running "$i"; then log "$(name "$i") already running"; continue; fi
    boot_vm "$i" "$GOLDEN" qcow2
    printf '    %s  ssh 127.0.0.1:%s  mac %s\n' "$(name "$i")" "$(port "$i")" "$(mac "$i")"
  done
  sleep 3
  local up=0
  for i in $(seq 1 "$COUNT"); do running "$i" && up=$((up+1)); done
  ok "$up/$COUNT VMs launched. Waiting for SSH will happen at 'provision' time."
}

# --------------------------------------------------------------------------- provision
cmd_provision(){
  [ -n "$TOKEN" ] || die "no enrollment token. Mint one on the VPS:
    curl -fsS -X POST http://localhost:8080/api/provision-tokens
  then: FLEET_TOKEN=<tok> $0 provision   (or write it to $FLEET_DIR/token)"
  log "provisioning against $OTA_URL ..."
  local i n uuid rc
  for i in $(seq 1 "$COUNT"); do
    running "$i" || { warn "$(name "$i") not running; skipping"; continue; }
    # Already enrolled? Re-running would mint a NEW uuid and create a duplicate device.
    if [ -f "$VMS_DIR/$(name "$i").provisioned" ] && [ -z "${FLEET_REPROVISION:-}" ]; then
      log "$(name "$i") already provisioned ($(cat "$VMS_DIR/$(name "$i").provisioned")); skipping (FLEET_REPROVISION=1 to force)"
      continue
    fi
    n="$(devname "$i")"
    log "$(name "$i") -> waiting for SSH..."
    if ! wait_ssh "$i" 240; then warn "$(name "$i") SSH timeout; skipping"; continue; fi
    log "$(name "$i") -> running provisioning one-liner as $n"
    if gssh "$i" "curl -fsSL $OTA_URL/provision-device.sh | sudo -n bash -s -- -s $OTA_URL -n $n -t $TOKEN -r" \
         > "$VMS_DIR/$(name "$i")-provision.log" 2>&1; then
      uuid=$(grep -oE 'Device UUID: [0-9a-f-]+' "$VMS_DIR/$(name "$i")-provision.log" | awk '{print $3}' | head -1)
      echo "${uuid:-unknown}" > "$VMS_DIR/$(name "$i").provisioned"
      ok "$(name "$i") provisioned as $n (uuid ${uuid:-?})"
    else
      warn "$(name "$i") provisioning failed; see $(name "$i")-provision.log"
      tail -3 "$VMS_DIR/$(name "$i")-provision.log" | sed 's/^/      /' >&2
    fi
  done
  ok "provisioning pass complete"
}

# --------------------------------------------------------------------------- status
cmd_status(){
  printf '%-6s %-8s %-7s %-9s %-14s %s\n' VM PORT RUN SSH DEVICE UUID
  local i r s p uuid
  for i in $(seq 1 "$COUNT"); do
    running "$i" && r="${c_grn}up${c_off}" || r="${c_red}down${c_off}"
    if running "$i" && gssh "$i" true 2>/dev/null; then s="${c_grn}ok${c_off}"; else s="-"; fi
    if [ -f "$VMS_DIR/$(name "$i").provisioned" ]; then p="yes"; uuid=$(cat "$VMS_DIR/$(name "$i").provisioned"); else p="no"; uuid="-"; fi
    printf '%-6s %-8s %-16b %-18b %-14s %s\n' "$(name "$i")" "$(port "$i")" "$r" "$s" "$([ "$p" = yes ] && devname "$i" || echo -)" "$uuid"
  done
}

# --------------------------------------------------------------------------- teardown
# Gracefully power off every running VM (fall back to kill after a grace period).
poweroff_vms(){
  local i end
  for i in $(seq 1 "$COUNT"); do
    running "$i" || continue
    gssh "$i" "sudo -n poweroff" 2>/dev/null || true
  done
  end=$(( $(date +%s) + 30 ))
  for i in $(seq 1 "$COUNT"); do
    while running "$i" && [ "$(date +%s)" -lt "$end" ]; do sleep 1; done
    running "$i" && pkill -f "qemu-system.*$(disk "$i")" 2>/dev/null || true
  done
}

# Recorded cloud UUIDs of provisioned VMs (one per line).
fleet_uuids(){ cat "$VMS_DIR"/*.provisioned 2>/dev/null | grep -E '^[0-9a-f-]{36}$' | sort -u; }

delete_overlays(){
  local i
  for i in $(seq 1 "$COUNT"); do
    rm -f "$(disk "$i")" "$(vars "$i")" "$(con "$i")" "$(qmp "$i")" \
          "$VMS_DIR/$(name "$i")-qemu.log" "$VMS_DIR/$(name "$i")-provision.log" \
          "$VMS_DIR/$(name "$i").provisioned"
  done
}

# stop: power off but keep overlays -> 'up' resumes the very same provisioned devices.
cmd_stop(){
  log "stopping VMs (overlays kept)..."
  poweroff_vms
  ok "fleet stopped. Resume the SAME devices with: $0 up"
}

# down: local teardown only. Cloud records remain (they just go stale/offline).
cmd_down(){
  local orphans; orphans="$(fleet_uuids | tr '\n' ' ')"
  log "powering off + deleting overlays..."
  poweroff_vms
  delete_overlays
  ok "fleet down (golden + base kept). Boot a fresh fleet with: $0 up && $0 provision"
  [ -n "$orphans" ] && warn "cloud still lists these devices (now orphaned): $orphans
      remove them with '$0 purge' next time, or delete them in the console."
  return 0
}

# purge: down + delete the cloud device records so nothing is left behind anywhere.
cmd_purge(){
  local uuids u ok_n=0 fail_n=0; uuids="$(fleet_uuids)"
  log "PURGE: power off, delete overlays, and remove cloud devices..."
  poweroff_vms
  if [ -z "$uuids" ]; then
    warn "no recorded device UUIDs found; nothing to delete in the cloud"
  elif [ -n "$VPS_SSH" ]; then
    for u in $uuids; do
      if $VPS_SSH "curl -fsS -X DELETE $DR_API/devices/$u" >/dev/null 2>&1; then
        ok "cloud device deleted: $u"; ok_n=$((ok_n+1))
      else warn "cloud delete FAILED: $u"; fail_n=$((fail_n+1)); fi
    done
    log "cloud: $ok_n deleted, $fail_n failed"
  else
    warn "FLEET_VPS_SSH not set -> NOT deleting cloud devices. Run this on the VPS:"
    for u in $uuids; do echo "    curl -fsS -X DELETE $DR_API/devices/$u"; done
  fi
  delete_overlays
  ok "purge complete."
}

# --------------------------------------------------------------------------- misc
cmd_ssh(){ local i="$1"; shift || true; gssh "$i" "$@"; }
cmd_console(){ command -v socat >/dev/null || die "socat not installed"; socat -,raw,echo=0,escape=0x1d "unix-connect:$(con "$1")"; }

usage(){ awk 'NR>=3 && /^#/{sub(/^# ?/,"");print;next} NR>=3{exit}' "$0"; }
case "${1:-}" in
  golden)    cmd_golden ;;
  up)        cmd_up ;;
  provision) cmd_provision ;;
  status)    cmd_status ;;
  stop)      cmd_stop ;;
  down)      cmd_down ;;
  purge)     cmd_purge ;;
  ssh)       shift; cmd_ssh "$@" ;;
  console)   shift; cmd_console "$@" ;;
  ""|-h|--help|help) usage ;;
  *) die "unknown command: $1 (try: golden up provision status stop down purge)" ;;
esac
