#!/usr/bin/env python3
"""Probes the changelog extractor that fills the release notes.

The release page is built from this, so a rule that quietly matches the wrong
section, or nothing, would publish the wrong text under a version number.
"""

import io
import sys
import tempfile
import unittest
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from changelog_section import main, parse_version, section  # noqa: E402

CHANGELOG = """# Changelog

Prose above the first heading.

## Unreleased

## 1.0.4 (70) - 11 September 2026

- Fixed: the newest thing.

## 1.0.3 (69)

- Fixed: a heading with no date still works.

## 1.0.2 (68) - 11 September 2026

- Fixed: the oldest thing.
"""


class ParseVersionTest(unittest.TestCase):
    def test_splits_name_and_build(self):
        self.assertEqual(parse_version("1.0.4+70"), ("1.0.4", "70"))
        self.assertEqual(parse_version("  10.20.30+123  "), ("10.20.30", "123"))

    def test_refuses_anything_else(self):
        for value in ("1.0.4", "1.0.4+", "v1.0.4+70", "1.0+70", ""):
            with self.subTest(value=value):
                with self.assertRaises(ValueError):
                    parse_version(value)


class SectionTest(unittest.TestCase):
    def test_stops_at_the_next_heading(self):
        self.assertEqual(section(CHANGELOG, "1.0.4", "70"), "- Fixed: the newest thing.")

    def test_reads_a_heading_without_a_date(self):
        self.assertEqual(
            section(CHANGELOG, "1.0.3", "69"),
            "- Fixed: a heading with no date still works.",
        )

    def test_reads_the_last_one_in_the_file(self):
        self.assertEqual(section(CHANGELOG, "1.0.2", "68"), "- Fixed: the oldest thing.")

    def test_is_none_when_the_version_is_absent(self):
        self.assertIsNone(section(CHANGELOG, "9.9.9", "999"))

    def test_does_not_match_another_build_of_the_same_name(self):
        self.assertIsNone(section(CHANGELOG, "1.0.4", "71"))


class MainTest(unittest.TestCase):
    def _changelog(self, directory):
        path = Path(directory) / "CHANGELOG.md"
        path.write_text(CHANGELOG, encoding="utf-8")
        return path

    def test_prints_the_section(self):
        with tempfile.TemporaryDirectory() as directory:
            path = self._changelog(directory)
            output = io.StringIO()
            with redirect_stdout(output):
                code = main(["1.0.4+70", "--changelog", str(path)])
            self.assertEqual(code, 0)
            self.assertEqual(output.getvalue(), "- Fixed: the newest thing.\n")

    def test_fails_when_the_section_is_missing(self):
        with tempfile.TemporaryDirectory() as directory:
            path = self._changelog(directory)
            errors = io.StringIO()
            with redirect_stderr(errors):
                code = main(["9.9.9+999", "--changelog", str(path)])
            self.assertEqual(code, 1)
            self.assertIn("no changelog section", errors.getvalue())

    def test_fails_on_an_unreadable_changelog(self):
        with tempfile.TemporaryDirectory() as directory:
            errors = io.StringIO()
            with redirect_stderr(errors):
                code = main(["1.0.4+70", "--changelog", str(Path(directory) / "no.md")])
            self.assertEqual(code, 2)
            self.assertIn("cannot read", errors.getvalue())

    def test_fails_on_a_version_it_cannot_parse(self):
        errors = io.StringIO()
        with redirect_stderr(errors):
            code = main(["nonsense"])
        self.assertEqual(code, 2)
        self.assertIn("not a pubspec version", errors.getvalue())

    def test_reads_the_repository_changelog_by_default(self):
        output = io.StringIO()
        errors = io.StringIO()
        with redirect_stdout(output), redirect_stderr(errors):
            code = main(["1.0.4+70"])
        self.assertEqual(code, 0, errors.getvalue())
        self.assertIn("notification extension", output.getvalue())


if __name__ == "__main__":
    unittest.main(verbosity=1)
