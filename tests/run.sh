#!/usr/bin/env bash
# Hindsight end-to-end tests.
#
# Builds a fake "laptop" (a home folder, /etc, Bluetooth and Wi-Fi state, boot
# files), backs it up into a temporary restic repository, and then restores it
# in every supported way: single files, older versions, in place, a full-system
# restore onto an empty disk, and a migration onto a fresh install.
#
# Needs restic and jq. Runs as a normal user: no root, drive or systemd needed.
set -uo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
hs=$here/bin/hindsight
command -v restic >/dev/null || { echo "SKIP: restic is not installed"; exit 0; }
command -v jq >/dev/null || { echo "SKIP: jq is not installed"; exit 0; }

t=$(mktemp -d)
trap 'chmod -R u+w "$t" 2>/dev/null; rm -rf "$t"' EXIT

export HINDSIGHT_ETC=$t/etc-hindsight HINDSIGHT_STATE=$t/state HINDSIGHT_RUN=$t/run HINDSIGHT_CACHE=$t/cache
export HINDSIGHT_ALLOW_NONROOT=1 HINDSIGHT_NO_SYSTEMD=1
export RESTIC_PROGRESS_FPS=0.1

me=$(id -un)
uid=$(id -u)
myhome=$(getent passwd "$me" | cut -d: -f6)
sys=$t/sys          # the fake laptop being backed up
repo=$t/repo

pass=0 fail=0
check() { # check "description" command...
  local desc=$1; shift
  if "$@" >/dev/null 2>&1; then echo "ok   - $desc"; pass=$((pass + 1))
  else echo "FAIL - $desc"; fail=$((fail + 1)); fi
}
same() { [[ -f $1 && $(cat "$1") == "$2" ]]; }
absent() { [[ ! -e $1 ]]; }
status() { "$hs" status --json | jq -r "$1"; }
count() { status '.snapshot_count // 0'; }
hs_quiet() { "$hs" "$@" </dev/null >"$t/last.out" 2>&1; }

# --------------------------------------------------------- the fake laptop ---

mk() { mkdir -p "$(dirname "$1")"; printf '%s' "$2" >"$1"; }
mk "$sys$myhome/Documents/report.txt"              "report v1"
mk "$sys$myhome/Documents/notes/todo.md"           "buy milk"
mk "$sys$myhome/.config/app/settings.conf"         "theme=dark"
mk "$sys$myhome/.cache/thumbnails/junk"            "cache"
mk "$sys$myhome/.local/share/Trash/files/old.txt"  "trash"
mk "$sys/etc/hostname"                             "oldlaptop"
mk "$sys/etc/pacman.conf"                          "[options] custom"
mk "$sys/etc/fstab"                                "UUID=OLD-DISK / btrfs"
mk "$sys/etc/crypttab"                             "root UUID=OLD-LUKS"
mk "$sys/etc/kernel/cmdline"                       "root=UUID=OLD-DISK"
mk "$sys/etc/default/limine"                       "OLD BOOT CONFIG"
mk "$sys/etc/NetworkManager/system-connections/home.nmconnection" "psk=secret"
mk "$sys/etc/hindsight/hindsight.conf"             "old hindsight config"
mk "$sys/boot/vmlinuz-linux"                       "old kernel"
mk "$sys/var/lib/bluetooth/AA:BB:CC:DD:EE:FF/info" "paired headphones"
mk "$sys/var/lib/iwd/home.psk"                     "wifi password"
mk "$sys/var/lib/hindsight/meta/pkglist-native.txt"  $'base\nfirefox'
mk "$sys/var/lib/hindsight/meta/pkglist-foreign.txt" "some-aur-package"
mk "$sys/var/lib/hindsight/meta/users.txt"         "$me:$uid:$myhome"
mk "$sys/var/lib/hindsight/meta/enabled-units.txt" "bluetooth.service enabled enabled"

mkdir -p "$HINDSIGHT_ETC"
cat >"$HINDSIGHT_ETC/hindsight.conf" <<CONF
REPOSITORY="$repo"
HOST_ID="testhost"
BACKUP_PATHS="$sys"
CONF
printf 'correct horse battery staple' >"$HINDSIGHT_ETC/password"
cat >"$HINDSIGHT_ETC/excludes" <<EXCL
$sys/home/*/.cache
$sys/home/*/.local/share/Trash
EXCL
RESTIC_PASSWORD_FILE=$HINDSIGHT_ETC/password restic init -r "$repo" -q >/dev/null

echo "# Backing up"

check "status before any backup says configured" test "$(status .configured)" = true
check "status before any backup has no last backup" test "$(status '.last_success // "none"')" = none

hs_quiet backup
check "first backup succeeds" test $? -eq 0
check "status is idle afterwards" test "$(status .state)" = idle
check "status records the snapshot id" test "$(status '.last_snapshot | length')" = 8
check "status counts one backup" test "$(count)" = 1
check "status reports when the next backup is due" test "$(status '.next_due > .last_success')" = true
check "backup list is readable without root" test -s "$HINDSIGHT_STATE/snapshots.json"
check "status lists recent backups" test "$(status '.recent | length')" = 1

hs_quiet backup --auto
check "automatic backup is skipped when not yet due" test "$(count)" = 1

sleep 1
printf 'report v2' >"$sys$myhome/Documents/report.txt"
printf 'theme=light' >"$sys$myhome/.config/app/settings.conf"
hs_quiet backup
check "second backup succeeds" test "$(count)" = 2

check "non-root list shows both backups" \
  test "$(env -u HINDSIGHT_ALLOW_NONROOT "$hs" list | wc -l)" = 2

first=$(jq -r 'sort_by(.time) | .[0].id' "$HINDSIGHT_STATE/snapshots.json")
latest=$(jq -r 'sort_by(.time) | .[-1].id' "$HINDSIGHT_STATE/snapshots.json")
check "backups have distinct ids" test "$first" != "$latest"

echo "# Restoring files"

out=$t/restored-latest
hs_quiet restore --to "$out" "$sys$myhome/Documents/report.txt"
check "restore a single file (latest version)" same "$out$sys$myhome/Documents/report.txt" "report v2"
check "restoring one file brings back only that file" absent "$out$sys$myhome/Documents/notes"

out=$t/restored-old
hs_quiet restore --snapshot "$first" --to "$out" "$sys$myhome/Documents/report.txt"
check "restore an older version of a file" same "$out$sys$myhome/Documents/report.txt" "report v1"

out=$t/restored-dir
hs_quiet restore --to "$out" "$sys$myhome"
check "restore a whole folder recursively" same "$out$sys$myhome/Documents/notes/todo.md" "buy milk"
check "hidden config files are restored" same "$out$sys$myhome/.config/app/settings.conf" "theme=light"
check "caches were never backed up" absent "$out$sys$myhome/.cache"
check "the Trash was never backed up" absent "$out$sys$myhome/.local/share/Trash"

rm -rf "$sys$myhome/Documents/notes"
hs_quiet restore --in-place --yes "$sys$myhome/Documents/notes"
check "restore a deleted folder in place" same "$sys$myhome/Documents/notes/todo.md" "buy milk"

printf 'oops, overwritten' >"$sys$myhome/Documents/report.txt"
hs_quiet restore --in-place --yes --snapshot "$first" "$sys$myhome/Documents/report.txt"
check "roll a file back to an older version in place" same "$sys$myhome/Documents/report.txt" "report v1"
printf 'report v2' >"$sys$myhome/Documents/report.txt"

hs_quiet restore
check "restore without a path is refused" test $? -ne 0

cp "$HINDSIGHT_ETC/password" "$t/password.good"
printf 'wrong password' >"$HINDSIGHT_ETC/password"
hs_quiet restore --to "$t/nope" "$sys$myhome/Documents"
check "restore with the wrong password fails" test $? -ne 0
check "a failed restore writes nothing" absent "$t/nope$sys"
cp "$t/password.good" "$HINDSIGHT_ETC/password"

echo "# Full-system restore (live USB onto a new disk)"

newroot=$t/newdisk
mk "$newroot/etc/fstab"          "UUID=NEW-DISK / btrfs"
mk "$newroot/etc/kernel/cmdline" "root=UUID=NEW-DISK"
mk "$newroot/boot/vmlinuz-linux" "new kernel"

hs_quiet restore-system --repo "$repo" --target "$t/not-a-mount"
check "refuses a target that isn't a mount point" test $? -ne 0

hs_quiet restore-system --repo "$t" --target "$newroot"
check "refuses a folder that isn't a backup repository" test $? -ne 0

HINDSIGHT_ALLOW_NONMOUNT=1 HINDSIGHT_SOURCE_PREFIX=$sys \
  hs_quiet restore-system --repo "$repo" --target "$newroot" --yes
check "full-system restore succeeds" test $? -eq 0
check "home folder is restored" same "$newroot$myhome/Documents/report.txt" "report v2"
check "system settings are restored" same "$newroot/etc/pacman.conf" "[options] custom"
check "Wi-Fi connections are restored" same "$newroot/etc/NetworkManager/system-connections/home.nmconnection" "psk=secret"
check "Bluetooth pairings are restored" same "$newroot/var/lib/bluetooth/AA:BB:CC:DD:EE:FF/info" "paired headphones"
check "the new disk's fstab is kept" same "$newroot/etc/fstab" "UUID=NEW-DISK / btrfs"
check "the new disk's kernel cmdline is kept" same "$newroot/etc/kernel/cmdline" "root=UUID=NEW-DISK"
check "the old crypttab is not restored" absent "$newroot/etc/crypttab"
check "the old boot config is not restored" absent "$newroot/etc/default/limine"
check "the new kernel in /boot is kept" same "$newroot/boot/vmlinuz-linux" "new kernel"

echo "# Migration onto a fresh Omarchy install"

fresh=$t/fresh
mk "$fresh/etc/fstab"                          "UUID=FRESH / btrfs"
mk "$fresh/etc/hostname"                       "omarchy"
mk "$fresh$myhome/.config/app/settings.conf"   "fresh default"
mk "$fresh$myhome/.bashrc"                     "fresh bashrc"

HINDSIGHT_SOURCE_PREFIX=$sys HINDSIGHT_TARGET_ROOT=$fresh \
  hs_quiet migrate --yes --skip-packages --user "$me"
check "migration succeeds" test $? -eq 0
check "documents are back" same "$fresh$myhome/Documents/report.txt" "report v2"
check "app settings from the backup replace the defaults" same "$fresh$myhome/.config/app/settings.conf" "theme=light"
check "files only on the new install are left alone" same "$fresh$myhome/.bashrc" "fresh bashrc"
check "caches are not brought over" absent "$fresh$myhome/.cache"
check "system settings are restored" same "$fresh/etc/pacman.conf" "[options] custom"
check "hostname comes back" same "$fresh/etc/hostname" "oldlaptop"
check "Wi-Fi connections (NetworkManager) come back" same "$fresh/etc/NetworkManager/system-connections/home.nmconnection" "psk=secret"
check "Wi-Fi passwords (iwd) come back" same "$fresh/var/lib/iwd/home.psk" "wifi password"
check "Bluetooth pairings come back" same "$fresh/var/lib/bluetooth/AA:BB:CC:DD:EE:FF/info" "paired headphones"
check "the fresh install's fstab is kept" same "$fresh/etc/fstab" "UUID=FRESH / btrfs"
check "the old crypttab is not brought over" absent "$fresh/etc/crypttab"
check "the old kernel cmdline is not brought over" absent "$fresh/etc/kernel/cmdline"
check "Hindsight's own settings on the new install are kept" absent "$fresh/etc/hindsight"
check "state that wasn't in the backup is skipped quietly" absent "$fresh/var/lib/fprint"
check "migration mentions what it restored" grep -q "bluetooth" "$t/last.out"

fresh2=$t/fresh-old-version
HINDSIGHT_SOURCE_PREFIX=$sys HINDSIGHT_TARGET_ROOT=$fresh2 \
  hs_quiet migrate --yes --skip-packages --user "$me" --snapshot "$first"
check "migrate from an older backup" same "$fresh2$myhome/.config/app/settings.conf" "theme=dark"

printf 'wrong password' >"$HINDSIGHT_ETC/password"
HINDSIGHT_SOURCE_PREFIX=$sys HINDSIGHT_TARGET_ROOT=$t/fresh3 \
  hs_quiet migrate --yes --skip-packages --user "$me"
check "migration with the wrong password fails" test $? -ne 0
check "a failed migration writes nothing" absent "$t/fresh3$myhome"
cp "$t/password.good" "$HINDSIGHT_ETC/password"

hs_quiet migrate --yes --skip-packages --user no-such-user-hindsight
check "migration for a missing user is refused" test $? -ne 0

echo "# Status and failure handling"

cp "$HINDSIGHT_STATE/status.json" "$t/status.good"
jq '.state="running" | .pid=999999' "$t/status.good" >"$HINDSIGHT_STATE/status.json"
check "a crashed backup is reported as interrupted" test "$(status .state)" = error
cp "$t/status.good" "$HINDSIGHT_STATE/status.json"

mv "$repo" "$repo.unplugged"
hs_quiet backup
check "backing up to a missing repository fails" test $? -ne 0
check "the failure shows in the status" test "$(status .state)" = error
check "the status explains the failure" test -n "$(status '.last_error // empty')"
mv "$repo.unplugged" "$repo"

hs_quiet backup
check "the next backup recovers from the error" test "$(status .state)" = idle

echo "# Retention"

before=$(count)
cat >>"$HINDSIGHT_ETC/hindsight.conf" <<CONF
KEEP_HOURLY=1
KEEP_DAILY=0
KEEP_WEEKLY=0
KEEP_MONTHLY=0
CONF
hs_quiet backup
check "old backups are thinned out by the retention policy" test "$(count)" -lt "$before"
check "the newest backup is always kept" test "$(count)" -ge 1

echo
echo "$pass passed, $fail failed"
(( fail == 0 ))
