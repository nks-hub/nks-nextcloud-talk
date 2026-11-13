#!/usr/bin/env python3
"""Probes the gate that keeps an incomplete release away from the desktop updaters."""

import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from publish_release import problems, required_assets

TAG = "v1.0.34+102"
COMPLETE = required_assets(TAG)
SUMS = "\n".join(f"{'0' * 64}  {name}" for name in COMPLETE if name not in ("SHA256SUMS", "appcast.xml"))


class PublishReleaseTest(unittest.TestCase):
    def test_complete_release_passes(self):
        self.assertEqual(problems(TAG, COMPLETE, SUMS), [])

    def test_release_without_the_mac_files_is_refused(self):
        assets = [a for a in COMPLETE if "macos" not in a and a != "appcast.xml"]
        self.assertEqual(problems(TAG, assets, SUMS),
                         ["missing asset nks-talk-macos-1.0.34-102.zip", "missing asset appcast.xml"])

    def test_release_without_the_windows_installer_is_refused(self):
        assets = [a for a in COMPLETE if not a.endswith(".exe")]
        self.assertIn("missing asset NKS-Talk-1.0.34-102-windows-x64-setup.exe", problems(TAG, assets, SUMS))

    def test_checksum_list_must_cover_the_mac_zip(self):
        sums = "\n".join(line for line in SUMS.splitlines() if "macos" not in line)
        self.assertEqual(problems(TAG, COMPLETE, sums), ["SHA256SUMS does not list nks-talk-macos-1.0.34-102.zip"])

    def test_binary_mode_marker_in_checksums_is_accepted(self):
        sums = SUMS.replace("  ", " *")
        self.assertEqual(problems(TAG, COMPLETE, sums), [])

    def test_rejects_a_tag_without_build_number(self):
        with self.assertRaises(ValueError):
            required_assets("v1.0.34")


if __name__ == "__main__":
    unittest.main()
