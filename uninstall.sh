#!/usr/bin/env bash
# Removes Hindsight from this computer. Your backups on the drive are NOT touched.
set -uo pipefail
[[ $EUID -ne 0 ]] || { echo "Run ./uninstall.sh as your normal user." >&2; exit 1; }

sudo systemctl disable --now hindsight-backup.timer 2>/dev/null
sudo systemctl stop hindsight-backup.service hindsight-backup-now.service 2>/dev/null
sudo rm -f /etc/systemd/system/hindsight-backup.{service,timer} /etc/systemd/system/hindsight-backup-now.service \
           /etc/polkit-1/rules.d/50-hindsight.rules /etc/udev/rules.d/90-hindsight.rules /usr/local/bin/hindsight
sudo systemctl daemon-reload
sudo udevadm control --reload 2>/dev/null

if command -v omarchy-bar >/dev/null; then
  python3 - "${XDG_CONFIG_HOME:-$HOME/.config}/omarchy/shell.json" <<'PY' || true
import json, sys
p = sys.argv[1]
c = json.load(open(p))
for section, items in c.get("bar", {}).get("layout", {}).items():
    c["bar"]["layout"][section] = [w for w in items if w.get("id") != "hindsight.backup"]
json.dump(c, open(p, "w"), indent=2)
PY
fi
rm -rf "${XDG_CONFIG_HOME:-$HOME/.config}/omarchy/plugins/hindsight.backup"

if [[ ${1:-} == --purge ]]; then
  sudo rm -rf /etc/hindsight /var/lib/hindsight /var/cache/hindsight
  echo "Removed settings, password and state too. (Backups on the drive are untouched.)"
else
  echo "Kept /etc/hindsight (settings and backup password). Use --purge to remove it."
fi
echo "Hindsight is uninstalled."
