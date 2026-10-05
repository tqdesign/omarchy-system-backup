#!/usr/bin/env bash
# Restore the newest backup into a throwaway disk image and check the result.
# Real drives and the firmware boot list are not touched. Needs free space on
# the backup drive roughly the size of one backup; the image is deleted after.
#
#   sudo ./test-restore.sh          # run, check, clean up
#   sudo ./test-restore.sh --keep   # keep the image (e.g. to boot it in a VM)
set -euo pipefail

((EUID == 0)) || exec sudo "$0" "$@"
KEEP=no
[[ ${1:-} == --keep ]] && KEEP=yes

HERE=$(cd "$(dirname "$0")" && pwd)
APP=$HERE/omarchy-backup
DEST=$(python3 -c 'import json,sys
try: print(json.load(open("/etc/omarchy-backup.json"))["dest"])
except Exception: print("/data/backups/system")')
WORK=$(dirname "$(dirname "$DEST")")/restore-test
IMG=$WORK/disk.img
KEY=$WORK/test.key
MAP=omarchy-restore-check
MNT=$WORK/mnt
LOG=/tmp/omarchy-restore-test.log
LOOP=""

: > "$LOG"
chmod 0644 "$LOG"
exec > >(tee -a "$LOG") 2>&1

fails=0
pass() { printf '  \033[32mPASS\033[0m  %s\n' "$*"; }
fail() { printf '  \033[31mFAIL\033[0m  %s\n' "$*"; fails=$((fails + 1)); }
check() { local what=$1; shift; if "$@" >/dev/null 2>&1; then pass "$what"; else fail "$what"; fi; }

cleanup() {
  set +e
  for m in "$MNT/boot" "$MNT/sys" "$MNT/top"; do mountpoint -q "$m" && umount "$m"; done
  [[ -e /dev/mapper/$MAP ]] && cryptsetup close "$MAP"
  [[ -n $LOOP ]] && losetup -d "$LOOP"
  if [[ $KEEP == no ]]; then
    rm -rf "$WORK"
  else
    echo "Kept $IMG (key: $KEY)"
  fi
}
trap cleanup EXIT

echo "== Restore test $(date -Is)"
[[ -d $DEST/snapshots ]] || { echo "No backups in $DEST"; exit 1; }
newest=$(OMARCHY_BACKUP_DEST=$DEST python3 "$APP" list | head -1 | cut -d' ' -f1)
[[ -n $newest ]] || { echo "No complete backup in $DEST"; exit 1; }
echo "Backup:  $newest"

command -v arch-chroot >/dev/null || pacman -S --needed --noconfirm arch-install-scripts

used=$(df --output=used -B1 "$DEST" | tail -1)
avail=$(df --output=avail -B1 "$DEST" | tail -1)
((avail > used * 11 / 10)) || { echo "Not enough free space on the backup drive for a test image"; exit 1; }

rm -rf "$WORK"
mkdir -p "$WORK"
chattr +C "$WORK" 2>/dev/null || true   # no copy-on-write for the image file
truncate -s "$(( (used * 3 / 2) / 1073741824 + 20 ))G" "$IMG"
head -c 64 /dev/urandom > "$KEY"
chmod 0400 "$KEY"
LOOP=$(losetup -fP --show "$IMG")
echo "Image:   $IMG on $LOOP ($(du -h --apparent-size "$IMG" | cut -f1) sparse)"

echo
echo "== Restoring"
start=$(date +%s)
OMARCHY_BACKUP_DEST=$DEST python3 "$APP" restore-system \
  --target "$LOOP" --backup-dir "$DEST" --at "$newest" \
  --no-efi-register --luks-key-file "$KEY" --yes
echo "Restore took $(( ($(date +%s) - start) / 60 )) min"

echo
echo "== Checking the restored drive"
esp=${LOOP}p1
luks=${LOOP}p2
partuuid=$(blkid -s PARTUUID -o value "$luks")
cryptsetup open --key-file "$KEY" "$luks" "$MAP"
root_uuid=$(blkid -s UUID -o value "/dev/mapper/$MAP")
esp_uuid=$(blkid -s UUID -o value "$esp")
mkdir -p "$MNT/top" "$MNT/sys" "$MNT/boot"
mount -o ro,subvolid=5 "/dev/mapper/$MAP" "$MNT/top"
mount -o ro,subvol=@ "/dev/mapper/$MAP" "$MNT/sys"
mount -o ro "$esp" "$MNT/boot"

subvols=$(btrfs subvolume list "$MNT/top" | awk '{print $NF}')
for s in @ @home @pkg @log @/.snapshots @/swap; do
  check "subvolume $s exists" grep -qx "$s" <<<"$subvols"
done
check "/home has the same users" diff <(ls /home) <(ls "$MNT/top/@home")
check "/etc/hostname matches" cmp /etc/hostname "$MNT/sys/etc/hostname"
check "swapfile created" test -s "$MNT/sys/swap/swapfile"
check "fstab: / on the new drive" grep -qE "^UUID=$root_uuid[[:space:]]+/[[:space:]]" "$MNT/sys/etc/fstab"
check "fstab: /home on the new drive" grep -qE "^UUID=$root_uuid[[:space:]]+/home[[:space:]]" "$MNT/sys/etc/fstab"
check "fstab: /boot on the new drive" grep -qE "^UUID=$esp_uuid[[:space:]]+/boot[[:space:]]" "$MNT/sys/etc/fstab"
check "fstab: /data entry kept" grep -qE "[[:space:]]/data[[:space:]]" "$MNT/sys/etc/fstab"
check "limine: cryptdevice points at the new partition" grep -q "cryptdevice=PARTUUID=$partuuid:" "$MNT/sys/etc/default/limine"
if [[ -f $MNT/sys/etc/limine-entry-tool.d/resume.conf ]]; then
  offset=$(btrfs inspect-internal map-swapfile -r "$MNT/sys/swap/swapfile")
  check "resume offset matches the new swapfile" grep -q "resume_offset=$offset" "$MNT/sys/etc/limine-entry-tool.d/resume.conf"
fi
check "Limine EFI binary on the ESP" test -n "$(find "$MNT/boot/EFI" -iname 'limine*.efi' -print -quit)"
uki=$(find "$MNT/boot" -iname '*.efi' -path '*Linux*' -newer "$IMG" -print -quit 2>/dev/null || true)
[[ -n $uki ]] || uki=$(find "$MNT/boot" -iname 'omarchy*.efi' -print -quit)
check "boot image (UKI) rebuilt" test -n "$uki"
if [[ -n $uki ]]; then
  check "boot image unlocks the new partition" grep -aq "cryptdevice=PARTUUID=$partuuid" "$uki"
fi
check "firmware boot list unchanged (no new Limine entry)" test "$(efibootmgr | grep -c Limine)" -le 1

echo
if ((fails)); then
  echo "== $fails check(s) FAILED. Full log: $LOG"
  exit 1
fi
echo "== All checks passed. Full log: $LOG"
