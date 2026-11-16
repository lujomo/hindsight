# Hindsight

Time Machine-style backups for [Omarchy](https://omarchy.org).

Plug in a drive and Hindsight backs up the whole laptop: your files, your settings, the installed system and a list of every package. It runs every hour while the drive is connected and again whenever you plug it in. A bar icon shows when the last backup happened. You can browse any past backup in Files and copy back what you need, or rebuild a new laptop from one.

Backups are encrypted, deduplicated [restic](https://restic.net) repositories, so after the first full backup each hourly run only stores what changed. Any copy of restic can read them, on any computer, without Hindsight.

## Install

```bash
git clone https://github.com/lujomo/hindsight ~/Projects/hindsight
cd ~/Projects/hindsight
./install.sh
```

The installer asks for sudo. It installs `restic`, the `hindsight` command, the systemd timer and the bar icon. Then it starts the setup wizard, which asks two things:

1. **Which drive to back up to.** exFAT, ext4, btrfs, XFS and NTFS all work, and the drive doesn't need to be reformatted. Other files on it are left alone. Backups go into a `Hindsight/<computer-name>` folder.
2. **A backup password.** You need it to restore on another computer, so keep it in your password manager. If you leave it empty, Hindsight generates one and shows it to you.

## Everyday use

| | |
|---|---|
| **Bar icon** (󰁯) | Click for the status popup: live progress, last/next backup, recent backups, and Back Up Now / Stop, Browse, Eject and More options. Right-click backs up now; middle-click browses. The icon pulses while backing up, dims when the drive is unplugged, and turns red if a backup failed or none has run for 10 days. |
| `hindsight status` | Last backup, drive state, how many backups are kept |
| `hindsight now` | Back up right away |
| `hindsight browse` | Opens every backup as a folder in Files. Copy out what you need |
| `sudo hindsight restore ~/Documents/thesis.odt` | Restores the latest version into `~/Restored/<date>/` |
| `sudo hindsight restore --snapshot 1a2b3c4d --in-place ~/.config/hypr` | Puts an older version back where it was |
| `hindsight list` | Lists all backups |
| `hindsight eject` | Unmounts and powers down the drive so you can unplug it |

### What gets backed up

Hindsight backs up `/`, `/boot`, `/home` and `/var/log`. It skips caches, the Trash, swap, snapper snapshots and anything listed in `/etc/hindsight/excludes`. Folders containing a [`CACHEDIR.TAG`](https://bford.info/cachedir/) file are skipped too. Each path is backed up without crossing into other filesystems or btrfs subvolumes. If you add a subvolume or mount, for example for Docker, add it to `BACKUP_PATHS` in `/etc/hindsight/hindsight.conf`. Each backup also saves your package lists, enabled services and disk layout to `/var/lib/hindsight/meta/`.

### Which backups are kept

Like Time Machine, Hindsight keeps hourly backups for the past 24 hours, daily backups for the past month, weekly backups for the past year, and monthly backups after that. When the drive gets down to 20 GB free, it deletes the oldest backups first. All of this can be changed in `/etc/hindsight/hindsight.conf`.

## Before you need it

* **Keep your backup password somewhere other than this laptop**, such as a password manager or on paper. Without it nobody can read the backups, including you. There is no recovery.
* **Do a restore drill** once your first backup has finished. Then you know restoring works before you depend on it:
  ```bash
  hindsight list                                  # your backups are listed
  sudo hindsight restore ~/Documents              # a copy appears in ~/Restored/<date>/
  hindsight browse                                # every backup opens in Files
  ```

## Restoring after a wipe or on a new laptop

This is the usual way back: install Omarchy fresh, then let Hindsight bring everything back on top.

1. **Install Omarchy** and create the **same username** you had before.
2. **Get Hindsight.** You can clone it from GitHub:
   ```bash
   git clone https://github.com/lujomo/hindsight ~/Projects/hindsight
   cd ~/Projects/hindsight && ./install.sh
   ```
   No internet? The drive carries a copy. Run `cp /run/media/$USER/<drive>/Hindsight/tools/* /tmp && chmod +x /tmp/restic /tmp/hindsight`. Then, in steps 3 and 4, use `sudo HINDSIGHT_RESTIC=/tmp/restic /tmp/hindsight` in place of `sudo hindsight`.
3. **Plug in the backup drive.** The setup wizard asks which drive to use. Pick it, choose **"Use the existing backups of '<old computer name>'"**, and enter your backup password.
4. **Bring everything back:**
   ```bash
   sudo hindsight migrate
   ```
   It asks before each step:
   | Step | What comes back |
   |---|---|
   | Packages | Every official package that was installed, then AUR packages via `yay` |
   | Home folder | All your files, dotfiles and app settings (`~/.config`, browser profiles, SSH keys, …). Files that exist only on the new install are left alone |
   | System settings | `/etc`: hostname, Wi-Fi connections, pacman config, users' groups, … |
   | Device state | Bluetooth pairings, Wi-Fi passwords (iwd), fingerprints, Thunderbolt authorisations, account pictures, Tailscale identity, cron jobs |
   | Services | Re-enables system services that were enabled before |
5. **Reboot.**

`migrate` never touches the files that belong to the new disk: `fstab`, `crypttab`, the kernel command line, the bootloader configuration, `/boot` and swap. Those come from the fresh install, so the laptop still boots. Add `--snapshot <id>` to migrate from an older backup (see `hindsight list`).

**What `migrate` does not bring back:** Docker images and volumes, system-wide Flatpaks, databases under `/var/lib` and anything else outside the paths above. All of it is still in the backup: copy it out with `hindsight browse`, or use the full-system restore below.

### Full-system restore from a live USB

This puts the *exact* old system back, `/var/lib` included. Copies of `restic` and `hindsight` are kept on the drive under `Hindsight/tools/`, and the same steps are in `Hindsight/README.txt` on the drive.

1. Install Omarchy on the new disk, so it gets partitions, encryption and a bootloader. Then boot the Omarchy/Arch USB.
2. Unlock the new disk and mount it at `/mnt`: the root subvolume, plus `/mnt/home` and `/mnt/var/log`.
3. Copy `Hindsight/tools/restic` and `Hindsight/tools/hindsight` to `/tmp`, run `chmod +x` on them, then:
   `sudo HINDSIGHT_RESTIC=/tmp/restic /tmp/hindsight restore-system --repo /run/media/.../Hindsight/<computer> --target /mnt`
4. Run `arch-chroot /mnt`, then `mkinitcpio -P && limine-update`, then exit and reboot.

As with `migrate`, the new disk's `fstab`, `crypttab`, kernel command line, bootloader configuration and `/boot` are kept.

## How it works

```
 hindsight-backup.timer (hourly) ─┐
 udev: drive plugged in ──────────┼─> hindsight-backup.service ─> hindsight backup --auto
 bar right-click / `hindsight now` ─> hindsight-backup-now.service ─> hindsight backup
                                                                       │
            restic backup ─> <drive>/Hindsight/<host>/ (encrypted)  <──┘
            status ─> /var/lib/hindsight/status.json ─> `hindsight status --json` ─> bar icon
```

* Backups run as root, so system files are captured with their owners and permissions. The password is stored in `/etc/hindsight/password` (mode 600).
* A polkit rule lets members of `wheel` start a backup from the bar without typing a password. Browsing and restoring still ask for sudo.
* Hindsight mounts the drive itself if it isn't mounted already, and unmounts it again afterwards.
* A backup interrupted by unplugging or sleep is simply finished at the next run. Restic never leaves a half-written backup behind.

## Development

```bash
tests/run.sh
```

The tests need `restic` and `jq` but no root, drive or systemd. They build a fake laptop (home folder, `/etc`, Bluetooth and Wi-Fi state, boot files) and back it up into a temporary repository. Then they restore it every supported way:
* single files, older versions, whole folders, and in place
* a full-system restore onto an "empty disk"
* a migration onto a "fresh install"

Each restore is checked for what must come back and what must not, such as the old `fstab`. They also cover retention, wrong passwords, a missing drive and crashed backups.

Layout: `bin/hindsight` (the whole CLI, in bash), `systemd/`, `polkit/`, `plugin/` (the Omarchy shell bar widget, QML), `install.sh` and `uninstall.sh`.

`./uninstall.sh` removes Hindsight but leaves your backups on the drive. Add `--purge` to also delete its settings and saved password.

## License

MIT
