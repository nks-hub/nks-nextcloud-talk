from __future__ import annotations

import gzip
import hashlib
import json
import tempfile
import unittest
import zipfile
from pathlib import Path

from release_license_gate import (
    BEGIN_NOTICE,
    END_NOTICE,
    FLUTTER_NOTICES,
    NOTICE_HASH_PROPERTY,
    NOTICE_SEPARATOR,
    NOTICE_TEXT,
    SBOM,
    THIRD_PARTY_NOTICES,
    GateError,
    validate_apk,
)


class ReleaseLicenseGateTest(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary_directory = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary_directory.name)
        self.lockfile = self.root / "pubspec.lock"
        self.lockfile.write_text(
            """packages:
  alpha:
    dependency: direct main
    description:
      name: alpha
      sha256: aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
      url: https://pub.dev
    source: hosted
    version: 1.0.0
  beta:
    dependency: transitive
    description:
      name: beta
      sha256: bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
      url: https://pub.dev
    source: hosted
    version: 2.0.0
  local_package:
    dependency: direct main
    description:
      path: ../../packages/local_package
    source: path
    version: 1.0.0
sdks:
  dart: ">=3.0.0 <4.0.0"
""",
            encoding="utf-8",
        )
        self.plugins = self.root / ".flutter-plugins-dependencies"
        self.plugins.write_text(
            json.dumps({"plugins": {"android": [], "ios": []}}),
            encoding="utf-8",
        )

    def tearDown(self) -> None:
        self.temporary_directory.cleanup()

    @staticmethod
    def _component(
        coordinate: str,
        notice_hash: str,
        *,
        license_id: str = "Apache-2.0",
    ) -> dict[str, object]:
        group, name, version = coordinate.split(":")
        return {
            "type": "library",
            "group": group,
            "name": name,
            "version": version,
            "purl": f"pkg:maven/{group}/{name}@{version}",
            "hashes": [{"alg": "SHA-256", "content": "a" * 64}],
            "licenses": [{"license": {"id": license_id}}],
            "properties": [
                {"name": NOTICE_HASH_PROPERTY, "value": notice_hash},
            ],
        }

    @staticmethod
    def _pub_component(
        package_name: str,
        version: str,
        archive_hash: str,
        notice_hash: str,
    ) -> dict[str, object]:
        return {
            "type": "library",
            "group": "pub.dev",
            "name": package_name,
            "version": version,
            "purl": f"pkg:pub/{package_name}@{version}",
            "hashes": [{"alg": "SHA-256", "content": archive_hash}],
            "licenses": [{"expression": "BSD-3-Clause AND Apache-2.0"}],
            "properties": [
                {"name": NOTICE_HASH_PROPERTY, "value": notice_hash},
            ],
        }

    @staticmethod
    def _flutter_notices(packages: list[str]) -> bytes:
        sections = [
            f"{package}\n\nCopyright holder\nLicense text\n"
            for package in packages
        ]
        return gzip.compress(NOTICE_SEPARATOR.join(sections).encode("utf-8"))

    @staticmethod
    def _third_party_notices(
        coordinates: list[str],
        notice_text: str,
        notice_hash: str,
        *,
        license_id: str = "Apache-2.0",
    ) -> bytes:
        components = "".join(f"Component: {coordinate}\n" for coordinate in coordinates)
        return (
            "Third-party notices for Android release runtime dependencies\n\n"
            f"{BEGIN_NOTICE}\n"
            f"{components}"
            f"License: {license_id}\n"
            f"Notice-SHA256: {notice_hash}\n"
            f"Notice-Bytes: {len(notice_text.encode('utf-8'))}\n"
            f"{NOTICE_TEXT}\n"
            f"{notice_text}"
            f"{END_NOTICE}\n"
        ).encode("utf-8")

    def _write_apk(
        self,
        *,
        flutter_packages: list[str] | None = None,
        components: list[dict[str, object]] | None = None,
        notice_coordinates: list[str] | None = None,
        notice_text: str = "Full license text\n",
        notice_hash: str | None = None,
        include_flutter: bool = True,
        include_sbom: bool = True,
        include_third_party: bool = True,
    ) -> Path:
        coordinate = "example.group:runtime:1.0.0"
        actual_notice_hash = hashlib.sha256(notice_text.encode("utf-8")).hexdigest()
        sbom_notice_hash = notice_hash or actual_notice_hash
        sbom_components = components or [
            self._component(coordinate, sbom_notice_hash),
        ]
        apk = self.root / "app-release.apk"
        with zipfile.ZipFile(apk, "w") as archive:
            if include_flutter:
                archive.writestr(
                    FLUTTER_NOTICES,
                    self._flutter_notices(flutter_packages or ["alpha", "beta"]),
                )
            if include_sbom:
                archive.writestr(
                    SBOM,
                    json.dumps(
                        {
                            "bomFormat": "CycloneDX",
                            "specVersion": "1.6",
                            "version": 1,
                            "components": sbom_components,
                        }
                    ),
                )
            if include_third_party:
                archive.writestr(
                    THIRD_PARTY_NOTICES,
                    self._third_party_notices(
                        notice_coordinates or [coordinate],
                        notice_text,
                        actual_notice_hash,
                    ),
                )
        return apk

    def test_valid_release_artifact_passes(self) -> None:
        counts = validate_apk(self._write_apk(), self.lockfile)
        self.assertEqual(
            counts,
            {"flutter_packages": 2, "android_components": 1},
        )

    def test_missing_flutter_notice_fails(self) -> None:
        apk = self._write_apk(flutter_packages=["alpha"])
        with self.assertRaisesRegex(GateError, "beta"):
            validate_apk(apk, self.lockfile)

    def test_android_plugin_can_be_covered_by_release_sbom(self) -> None:
        archive_hash = "c" * 64
        lockfile = self.lockfile.read_text(encoding="utf-8").replace(
            "sdks:\n",
            """  android_native:
    dependency: transitive
    description:
      name: android_native
      sha256: "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"
      url: https://pub.dev
    source: hosted
    version: 3.0.0
sdks:
""",
        )
        self.lockfile.write_text(lockfile, encoding="utf-8")
        self.plugins.write_text(
            json.dumps(
                {
                    "plugins": {
                        "android": [{"name": "android_native"}],
                        "ios": [],
                    }
                }
            ),
            encoding="utf-8",
        )
        notice_text = "Full license text\n"
        notice_hash = hashlib.sha256(notice_text.encode("utf-8")).hexdigest()
        maven = self._component("example.group:runtime:1.0.0", notice_hash)
        pub = self._pub_component(
            "android_native",
            "3.0.0",
            archive_hash,
            notice_hash,
        )
        pub["licenses"] = [{"license": {"id": "Apache-2.0"}}]
        apk = self._write_apk(
            components=[maven, pub],
            notice_coordinates=[
                "example.group:runtime:1.0.0",
                "pub:android_native:3.0.0",
            ],
        )

        counts = validate_apk(apk, self.lockfile)
        self.assertEqual(counts["flutter_packages"], 3)
        self.assertEqual(counts["android_components"], 2)

    def test_flutter_noticed_pub_component_fails_as_redundant(self) -> None:
        notice_text = "Full license text\n"
        notice_hash = hashlib.sha256(notice_text.encode("utf-8")).hexdigest()
        maven = self._component("example.group:runtime:1.0.0", notice_hash)
        pub = self._pub_component("alpha", "1.0.0", "a" * 64, notice_hash)
        apk = self._write_apk(
            components=[maven, pub],
            notice_coordinates=[
                "example.group:runtime:1.0.0",
                "pub:alpha:1.0.0",
            ],
        )

        with self.assertRaisesRegex(GateError, "redundantly covers.*alpha"):
            validate_apk(apk, self.lockfile)

    def test_missing_jvm_notice_fails(self) -> None:
        apk = self._write_apk(notice_coordinates=["example.group:other:1.0.0"])
        with self.assertRaisesRegex(GateError, "unknown component"):
            validate_apk(apk, self.lockfile)

    def test_unknown_license_fails(self) -> None:
        text = "Full license text\n"
        digest = hashlib.sha256(text.encode("utf-8")).hexdigest()
        component = self._component(
            "example.group:runtime:1.0.0",
            digest,
            license_id="NOASSERTION",
        )
        apk = self._write_apk(components=[component])
        with self.assertRaisesRegex(GateError, "Unknown SPDX license"):
            validate_apk(apk, self.lockfile)

    def test_changed_notice_text_fails(self) -> None:
        apk = self._write_apk(notice_hash="b" * 64)
        with self.assertRaisesRegex(GateError, "Notice hash mismatch"):
            validate_apk(apk, self.lockfile)

    def test_duplicate_sbom_component_fails(self) -> None:
        text = "Full license text\n"
        digest = hashlib.sha256(text.encode("utf-8")).hexdigest()
        component = self._component("example.group:runtime:1.0.0", digest)
        apk = self._write_apk(components=[component, component])
        with self.assertRaisesRegex(GateError, "Duplicate SBOM component"):
            validate_apk(apk, self.lockfile)

    def test_missing_required_artifact_entry_fails(self) -> None:
        apk = self._write_apk(include_third_party=False)
        with self.assertRaisesRegex(GateError, THIRD_PARTY_NOTICES):
            validate_apk(apk, self.lockfile)


if __name__ == "__main__":
    unittest.main()
