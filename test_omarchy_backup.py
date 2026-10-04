#!/usr/bin/env python3
import importlib.machinery
import importlib.util
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
loader = importlib.machinery.SourceFileLoader("omarchy_backup", str(HERE / "omarchy-backup"))
spec = importlib.util.spec_from_loader("omarchy_backup", loader)
B = importlib.util.module_from_spec(spec)
loader.exec_module(B)

FSTAB = """\
# Static information about the filesystems.
UUID=old-root\t/\tbtrfs\trw,relatime,compress=zstd:3,ssd,space_cache=v2,subvol=/@\t0 0
UUID=old-root\t/home\tbtrfs\trw,relatime,subvol=/@home\t0 0
UUID=old-root\t/var/cache/pacman/pkg\tbtrfs\trw,subvol=/@pkg\t0 0
UUID=old-root\t/var/log\tbtrfs\trw,subvol=/@log\t0 0
UUID=627C-78C3\t/boot\tvfat\trw,relatime\t0 2
UUID=data-fs\t/data\tbtrfs\trw,nofail\t0 0
/swap/swapfile none swap defaults,pri=0 0 0
"""


class RetentionTests(unittest.TestCase):
    def test_keeps_latest_per_day_week_month(self):
        stamps = [
            "20261005T030000", "20261005T120000",  # same day: keep the newer
            "20261004T030000", "20261003T030000",
            "20260920T030000", "20260801T030000", "20250101T030000",
        ]
        keep = B.stamps_to_keep(stamps, daily=2, weekly=2, monthly=3)
        self.assertIn("20261005T120000", keep)
        self.assertNotIn("20261005T030000", keep)
        self.assertIn("20261004T030000", keep)         # 2nd day
        self.assertNotIn("20261003T030000", keep)      # same ISO week as 10-04, which is newer
        self.assertIn("20260920T030000", keep)         # September month
        self.assertIn("20260801T030000", keep)         # August month
        self.assertNotIn("20250101T030000", keep)      # beyond 3 months

    def test_always_keeps_latest(self):
        self.assertEqual(B.stamps_to_keep(["20261005T030000"], 0, 0, 0), {"20261005T030000"})

    def test_empty(self):
        self.assertEqual(B.stamps_to_keep([], 7, 4, 6), set())


class StampTests(unittest.TestCase):
    def test_complete_requires_every_subvolume(self):
        with tempfile.TemporaryDirectory() as tmp:
            for name in ("@.20261005T030000", "@home.20261005T030000", "@.20261004T030000", "@home.junk"):
                Path(tmp, name).mkdir()
            self.assertEqual(B.complete_stamps(tmp), ["20261005T030000"])
            self.assertEqual(B.stamps_for(tmp, "@"), {"20261005T030000", "20261004T030000"})

    def test_missing_directory(self):
        self.assertEqual(B.complete_stamps("/nonexistent/x"), [])


class RestoreConfigTests(unittest.TestCase):
    def test_fstab_points_at_new_drive(self):
        out = B.rewrite_fstab(FSTAB, "new-root", "NEW-ESP")
        lines = out.splitlines()
        self.assertEqual(lines[0], "# Static information about the filesystems.")
        for mount in ("/", "/home", "/var/cache/pacman/pkg", "/var/log"):
            line = next(l for l in lines if l.split()[1:2] == [mount])
            self.assertTrue(line.startswith("UUID=new-root\t"), line)
            self.assertIn("subvol=", line)
        self.assertIn("UUID=NEW-ESP\t/boot\tvfat", out)
        self.assertIn("UUID=data-fs\t/data", out)  # the backup drive is untouched
        self.assertIn("/swap/swapfile none swap", out)

    def test_cryptdevice_and_resume(self):
        text = 'KERNEL_CMDLINE[default]+="cryptdevice=PARTUUID=5b5d-old:root root=/dev/mapper/root"'
        self.assertIn("cryptdevice=PARTUUID=new-uuid:root", B.set_cryptdevice(text, "new-uuid"))
        self.assertEqual(B.set_resume_offset('+=" resume_offset=1922495"', "42"), '+=" resume_offset=42"')

    def test_partition_names(self):
        self.assertEqual(B.partition_path("/dev/nvme1n1", 2), "/dev/nvme1n1p2")
        self.assertEqual(B.partition_path("/dev/loop0", 1), "/dev/loop0p1")
        self.assertEqual(B.partition_path("/dev/sda", 1), "/dev/sda1")


class RestorePathTests(unittest.TestCase):
    def test_keep_both_and_replace(self):
        with tempfile.TemporaryDirectory() as tmp:
            src = Path(tmp, "backup", "notes")
            src.mkdir(parents=True)
            (src / "a.txt").write_text("old")
            live = Path(tmp, "home", "notes")
            live.mkdir(parents=True)
            (live / "a.txt").write_text("new")
            (live / "extra.txt").write_text("x")

            kept = B.restore_path(src, live, "copy")
            self.assertNotEqual(kept, live)
            self.assertEqual((kept / "a.txt").read_text(), "old")
            self.assertEqual((live / "a.txt").read_text(), "new")

            B.restore_path(src, live, "replace")
            self.assertEqual((live / "a.txt").read_text(), "old")
            self.assertFalse((live / "extra.txt").exists())


class UnitFileTests(unittest.TestCase):
    def test_timer_and_service(self):
        self.assertIn("OnCalendar=*-*-* 03:00:00", B.timer_text("03:00"))
        self.assertIn("Persistent=true", B.timer_text("03:00"))
        self.assertIn("RequiresMountsFor=/data/backups", B.service_text("/data/backups/system"))
        self.assertIn("ExecStart=/usr/local/bin/omarchy-backup run", B.service_text("/x/y"))


if __name__ == "__main__":
    unittest.main()
