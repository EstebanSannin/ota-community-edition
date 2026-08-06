#!/usr/bin/env bash
# Emit a SELF-CONTAINED install-reporter.sh (base64-embeds the device-reporter files + the install
# steps) to stdout. Regenerate the served copy whenever these files change:
#   ./device-reporter/make-installer.sh > provisioner/install-reporter.sh
set -euo pipefail
cd "$(dirname "$0")"

cat <<'HDR'
#!/usr/bin/env bash
# Self-contained installer for the OTA-CE device hardware reporter.
# GENERATED from device-reporter/ by make-installer.sh — do not edit by hand.
set -euo pipefail
[ "$(id -u)" -eq 0 ] || { echo "install-reporter: run as root"; exit 1; }
umask 022
_w(){ mkdir -p "$(dirname "$1")"; base64 -d > "$1"; chmod "$2" "$1"; }
HDR

gen(){ # <src> <dest> <mode>
  echo "_w '$2' '$3' <<'__B64__'"
  base64 < "$1"
  echo "__B64__"
}
gen ota-hwinfo.sh         /var/lib/ota-hwinfo/ota-hwinfo.sh                                 755
gen ota-hwinfo.service    /etc/systemd/system/ota-hwinfo.service                           644
gen ota-hwinfo.timer      /etc/systemd/system/ota-hwinfo.timer                             644
gen 99-ota-hwinfo.rules   /etc/udev/rules.d/99-ota-hwinfo.rules                            644
gen aktualizr-hwinfo.conf /etc/systemd/system/aktualizr-torizon.service.d/10-hwinfo.conf   644

cat <<'FTR'
systemctl daemon-reload
udevadm control --reload 2>/dev/null || true
systemctl enable --now ota-hwinfo.timer 2>/dev/null || true
/var/lib/ota-hwinfo/ota-hwinfo.sh || true
# one controlled restart to publish initial system_info — skipped if an OSTree update is pending
if ostree admin status 2>/dev/null | grep -q '(pending)'; then
  echo "install-reporter: OSTree update pending — not restarting aktualizr; report publishes after the next reboot."
else
  systemctl restart aktualizr-torizon 2>/dev/null || systemctl restart aktualizr 2>/dev/null || true
  echo "install-reporter: done — reporter installed and initial system_info published."
fi
FTR
