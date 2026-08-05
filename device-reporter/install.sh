#!/bin/bash
# Install the OTA-CE device reporter on a Torizon device (run as root; /usr is read-only, so
# everything lands in writable /var and /etc).
set -euo pipefail
[ "$(id -u)" -eq 0 ] || { echo "run as root (sudo)"; exit 1; }
D="$(cd "$(dirname "$0")" && pwd)"

install -D -m755 "$D/ota-hwinfo.sh"        /var/lib/ota-hwinfo/ota-hwinfo.sh
install -D -m644 "$D/ota-hwinfo.service"   /etc/systemd/system/ota-hwinfo.service
install -D -m644 "$D/ota-hwinfo.timer"     /etc/systemd/system/ota-hwinfo.timer
install -D -m644 "$D/99-ota-hwinfo.rules"  /etc/udev/rules.d/99-ota-hwinfo.rules
install -D -m644 "$D/aktualizr-hwinfo.conf" /etc/systemd/system/aktualizr-torizon.service.d/10-hwinfo.conf

systemctl daemon-reload
udevadm control --reload
systemctl enable --now ota-hwinfo.timer
/var/lib/ota-hwinfo/ota-hwinfo.sh   # writes /var/sota/hwinfo.json (never restarts aktualizr)

# One controlled restart so the enriched system_info publishes now — but ONLY if no OSTree update
# is pending, so we never interrupt an in-progress update. After this, the reporter never restarts
# aktualizr again; new data publishes on the next reboot.
if ostree admin status 2>/dev/null | grep -q '(pending)'; then
  echo "ota-hwinfo installed — an OSTree update is pending, so NOT restarting aktualizr; enriched system_info will publish after the next reboot."
else
  systemctl restart aktualizr-torizon 2>/dev/null || systemctl restart aktualizr 2>/dev/null || true
  echo "ota-hwinfo installed and enabled (published initial system_info)."
fi
