# Omarchy System Backup

A terminal program for backing up an [Omarchy](https://omarchy.org) system to a
second drive and restoring it, similar in spirit to Macrium Reflect. You can
restore a single file or folder, or rebuild the whole system onto a new drive
after the old one dies.

It is one Python file with no dependencies beyond what Omarchy already ships.
The same program runs on your desktop and from a live USB stick on restore day.

```
Omarchy System Backup
Main menu

Last backup:  2026-10-05 03:04  ✓
Backups:      9 in /data/backups/system  ·  610.2 GB free
Schedule:     nightly at 03:00
Drive password: set

▸ Back up now
  Browse backups
  Restore a file or folder
  Restore whole system onto a new drive
  Open a backup drive (on a live USB)
  Schedule
  Set up / repair
  Quit
```

## How it works

Omarchy installs onto btrfs, with `/` and `/home` in the subvolumes `@` and
`@home`. This program:

1. Takes read-only snapshots of `@` and `@home`. This is instant.
2. Copies them with `btrfs send | btrfs receive` to a btrfs filesystem on
   another drive. After the first full copy, only the changes are sent, so
   nightly runs are quick.
3. Keeps the newest backup for each of the last 7 days, 4 weeks and 6 months.
4. Saves what a full restore needs once the original drive is gone: a copy of
   `/boot`, the partition layout, the swapfile size, the package list, the
   program itself, and `HOW-TO-RESTORE.txt`.

A whole-system restore partitions the new drive (2 GiB EFI plus LUKS2-encrypted
btrfs), copies the subvolumes back, and recreates `@pkg`, `@log`,
`/.snapshots` and the swapfile. It then points `fstab`, the Limine kernel
command line and the hibernation resume offset at the new drive, and
reinstalls Limine and rebuilds the boot image.

## Requirements

- Omarchy, or another Arch setup using the same layout: btrfs on LUKS, with
  `@` and `@home` subvolumes and Limine.
- A second drive formatted as btrfs and mounted. The default backup folder is
  `/data/backups/system`; change it under **Set up / repair**.
- For a full restore: an Omarchy or Arch live USB, which provides
  `arch-chroot`, `cryptsetup` and `btrfs`.

## Install

```bash
git clone https://github.com/tqdesign/omarchy-system-backup.git
cd omarchy-system-backup
sudo ./omarchy-backup
```

Then, in the menu:

1. **Set up / repair → Install / update**. This copies the program to
   `/usr/local/bin/omarchy-backup` and turns on a nightly systemd timer. A run
   that was missed because the laptop was off happens at the next startup.
2. **Set up / repair → Add a password to the backup drive**, if the drive
   unlocks with a key file. That key file lives on the system drive, so you
   need a password to open the backups after the system drive dies.
3. **Back up now**.

## Restoring

**A file or folder:** choose **Restore a file or folder**, pick a backup,
browse to the item and press `r`. If the item still exists, you choose between
saving the backup copy next to it (`name.restored-YYYYMMDD`) and replacing it.

**The whole system**, after a drive failure:

1. Fit the new drive and start from an Omarchy or Arch USB stick.
2. Unlock and mount the backup drive. Use `lsblk` to find it.
   ```bash
   cryptsetup open /dev/nvme0n1p1 backup
   mount /dev/mapper/backup /mnt
   python3 /mnt/backups/omarchy-backup
   ```
3. Choose **Restore whole system onto a new drive**, pick a backup and the
   new drive, and type the drive's name to confirm. You'll set a new startup
   password for the restored drive.
4. Restart.

Drives that are mounted, unlocked or hold the backup can't be selected.

## Command line

```bash
omarchy-backup                  # menu
omarchy-backup run              # one backup (what the timer runs)
omarchy-backup list             # list backups
omarchy-backup restore-system --target /dev/nvmeXn1 [--at 20261005T030000]
```

## Development

```bash
python3 -m unittest test_omarchy_backup   # unit tests
sudo ./test-restore.sh                     # full restore into a throwaway disk image
```

`test-restore.sh` restores the newest backup into a temporary image file next to
the backups, checks the result (subvolumes, files, fstab, boot settings, rebuilt
boot image) and deletes the image. Real drives and the firmware boot list are
not touched.

## Status

Early. The whole-system restore has not been tested on real hardware yet.
Restore onto a spare drive once before you rely on it. A backup only protects
you if the restore works.

## License

MIT. See [LICENSE](LICENSE).
