#!/usr/bin/env bash
# Installs Hindsight: the CLI, systemd units, polkit rule and the Omarchy bar icon,
# then runs the setup wizard. Run as your normal user; it asks for sudo.
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
plugin_dir=${XDG_CONFIG_HOME:-$HOME/.config}/omarchy/plugins/hindsight.backup

[[ $EUID -ne 0 ]] || { echo "Run ./install.sh as your normal user (not with sudo)." >&2; exit 1; }

echo "==> Installing packages (restic, jq, fuse3)"
sudo pacman -S --needed --noconfirm restic jq fuse3

echo "==> Installing the hindsight command and services"
sudo install -Dm755 "$here/bin/hindsight" /usr/local/bin/hindsight
for unit in hindsight-backup.service hindsight-backup-now.service hindsight-backup.timer; do
  sudo install -Dm644 "$here/systemd/$unit" "/etc/systemd/system/$unit"
done
sudo install -Dm644 "$here/polkit/50-hindsight.rules" /etc/polkit-1/rules.d/50-hindsight.rules
sudo systemctl daemon-reload

echo "==> Installing the bar icon"
mkdir -p "$plugin_dir"
cp -r "$here/plugin/." "$plugin_dir/"
if command -v omarchy-bar >/dev/null; then
  # The shell must discover the new plugin before the bar will accept it.
  omarchy-shell -q shell rescanPlugins
  if ! grep -q '"hindsight.backup"' "${XDG_CONFIG_HOME:-$HOME/.config}/omarchy/shell.json" 2>/dev/null; then
    placed=0
    for _ in 1 2 3 4 5 6 7 8 9 10; do
      omarchy-bar put hindsight.backup --before omarchy.bluetooth >/dev/null 2>&1 \
        || omarchy-bar put hindsight.backup --section right >/dev/null 2>&1
      if grep -q '"hindsight.backup"' "${XDG_CONFIG_HOME:-$HOME/.config}/omarchy/shell.json"; then
        placed=1; break
      fi
      sleep 1
    done
    (( placed )) || echo "   Could not add the icon automatically. Run: omarchy bar put hindsight.backup --section right"
  fi
fi

echo "==> Setting up your backup drive"
sudo /usr/local/bin/hindsight setup
