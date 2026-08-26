from __future__ import annotations

import contextlib
import io
import subprocess
import tempfile
import unittest
from pathlib import Path

from secret_log_scan import ScanError, main, scan_repository


class SecretLogScanTest(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary_directory = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary_directory.name)
        subprocess.run(
            ["git", "init", "--quiet", str(self.root)],
            check=True,
            capture_output=True,
            text=True,
        )

    def tearDown(self) -> None:
        self.temporary_directory.cleanup()

    def _write(self, relative_path: str, content: str) -> Path:
        target = self.root / relative_path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(content, encoding="utf-8")
        return target

    def _track(self, relative_path: str) -> None:
        subprocess.run(
            ["git", "-C", str(self.root), "add", "--", relative_path],
            check=True,
            capture_output=True,
            text=True,
        )

    def test_clean_tracked_source_passes(self) -> None:
        self._write(
            "lib/config.dart",
            """const apiToken = String.fromEnvironment("API_TOKEN");
final token = response.token;
headers['Authorization'] = 'Basic ${encodedCredentials}';
const testPassword = 'short-fixture';
const token = '123e4567-e89b-12d3-a456-426614174000';
""",
        )
        self._track("lib/config.dart")

        self.assertEqual(scan_repository(self.root), [])

    def test_tracked_secret_assignment_is_reported_without_value(self) -> None:
        secret_value = "regression" + "-only-value-42"
        self._write("lib/config.dart", f'password = "{secret_value}"\n')
        self._track("lib/config.dart")

        findings = scan_repository(self.root)

        self.assertEqual(len(findings), 1)
        self.assertEqual(findings[0].path, "lib/config.dart")
        self.assertEqual(findings[0].line_number, 1)
        self.assertEqual(findings[0].rule_id, "credential-assignment")
        self.assertNotIn(secret_value, findings[0].render())

    def test_untracked_source_is_not_scanned_implicitly(self) -> None:
        secret_value = "untracked" + "-regression-value-42"
        self._write("scratch.log", f'token={secret_value}\n')

        self.assertEqual(scan_repository(self.root), [])

    def test_explicit_runtime_log_artifact_is_scanned(self) -> None:
        secret_value = "artifact" + "-regression-value-42"
        artifact = self._write(
            "build/runtime.log",
            f"Authorization: Bearer {secret_value}\n",
        )

        findings = scan_repository(self.root, artifacts=[artifact])

        self.assertEqual(len(findings), 1)
        self.assertEqual(findings[0].path, "build/runtime.log")
        self.assertEqual(findings[0].rule_id, "authorization-value")
        self.assertNotIn(secret_value, findings[0].render())

    def test_explicit_artifact_directory_is_scanned_recursively(self) -> None:
        self._write("build/clean.txt", "build completed\n")
        secret_value = "cookie" + "-regression-value-42"
        self._write("build/logs/app.log", f"Cookie: session={secret_value}\n")

        findings = scan_repository(self.root, artifacts=[self.root / "build"])

        self.assertEqual(
            [(finding.path, finding.rule_id) for finding in findings],
            [("build/logs/app.log", "cookie-value")],
        )

    def test_private_key_header_is_reported(self) -> None:
        self._write("config/key.pem", "-----BEGIN PRIVATE KEY-----\n")
        self._track("config/key.pem")

        findings = scan_repository(self.root)

        self.assertEqual(len(findings), 1)
        self.assertEqual(findings[0].rule_id, "private-key")

    def test_cli_returns_one_and_never_prints_secret_value(self) -> None:
        secret_value = "cli" + "-regression-value-42"
        self._write("config.env", f'api_key="{secret_value}"\n')
        self._track("config.env")
        stdout = io.StringIO()
        stderr = io.StringIO()

        with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
            exit_code = main(["--root", str(self.root)])

        output = stdout.getvalue() + stderr.getvalue()
        self.assertEqual(exit_code, 1)
        self.assertIn("config.env:1:credential-assignment", output)
        self.assertNotIn(secret_value, output)

    def test_cli_returns_two_for_missing_artifact(self) -> None:
        stderr = io.StringIO()

        with contextlib.redirect_stderr(stderr):
            exit_code = main(
                [
                    "--root",
                    str(self.root),
                    "--artifact",
                    str(self.root / "missing.log"),
                ]
            )

        self.assertEqual(exit_code, 2)
        self.assertIn("does not exist", stderr.getvalue())

    def test_non_git_root_raises_safe_error(self) -> None:
        nested = self.root / "not-a-repository"
        nested.mkdir()

        with self.assertRaises(ScanError):
            scan_repository(nested)


if __name__ == "__main__":
    unittest.main()
