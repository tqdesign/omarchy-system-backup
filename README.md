# Omarchy System Backup

One terminal program that backs up `/` and `/home` to a second drive and
restores them: a single file or folder, or the whole system onto a new drive.

```bash
./omarchy-backup          # opens the menu (asks for your password via sudo)
```

## Menu

| Item | What it does |
|---|---|
| Back up now | Snapshot `/` and `/home` and copy them to `/data/backups/system`. The first run copies everything; later runs copy only changes. |
| Browse backups | Pick a backup to restore from or delete. |
| Restore a file or folder | Browse inside a backup and copy something back, either next to the current version or replacing it. |
| Restore whole system | Erase a new drive and rebuild a bootable Omarchy system on it from a backup. Drives that are in use or hold the backup can't be picked. |
| Open a backup drive | On a live USB: unlock the encrypted backup drive so its backups show up. |
| Schedule | Turn the nightly backup on or off and change its time (default 03:00; a missed run happens at the next startup). |
| Set up / repair | Install the program and nightly schedule, add a password to the backup drive, or change the backup folder. |

Kept on the backup drive: the newest backup for each of the last 7 days, 4 weeks
and 6 months. Each run also saves `/boot`, the partition layout and package
list, plus a copy of this program and `HOW-TO-RESTORE.txt` in `/data/backups/`.

## First-time setup

1. `sudo ./omarchy-backup` → **Set up / repair** → **Install**
2. **Set up / repair** → **Add a password to the backup drive**. Without it, the
   backup drive can only be unlocked by a key file on the system drive, which is
   gone if that drive dies.
3. **Back up now**

## Restore day (system drive died)

Boot an Omarchy or Arch USB stick, then:

```bash
cryptsetup open /dev/nvme0n1p1 backup        # the backup drive; check with lsblk
mount /dev/mapper/backup /mnt
python3 /mnt/backups/omarchy-backup          # → Restore whole system
```

## Command line

```bash
omarchy-backup run              # one backup (what the timer runs)
omarchy-backup list             # list backups
omarchy-backup restore-system --target /dev/nvmeXn1 [--at 20261005T030000]
```

## Tests

```bash
python3 -m unittest test_omarchy_backup
```
