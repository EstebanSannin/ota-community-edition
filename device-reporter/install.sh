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
/var/lib/ota-hwinfo/ota-hwinfo.sh   # initial report (writes the file + restarts aktualizr)
echo "ota-hwinfo installed and enabled."
