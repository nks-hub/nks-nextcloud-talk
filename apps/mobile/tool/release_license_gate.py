#!/usr/bin/env python3
"""Validate third-party notices embedded in Android and iOS releases."""

from __future__ import annotations

import argparse
import gzip
import hashlib
import io
import json
import re
import sys
import zipfile
from dataclasses import dataclass
from pathlib import Path
from typing import Any


FLUTTER_NOTICES = "assets/flutter_assets/NOTICES.Z"
IOS_FLUTTER_NOTICES = "Frameworks/App.framework/flutter_assets/NOTICES.Z"
SBOM = "assets/release_licenses/SBOM.json"
THIRD_PARTY_NOTICES = "assets/release_licenses/THIRD_PARTY_NOTICES.txt"
NOTICE_HASH_PROPERTY = "com.nkshub.nextcloudtalk.noticeSha256"
NOTICE_SEPARATOR = "-" * 80
BEGIN_NOTICE = "----- BEGIN COMPONENT NOTICE -----"
NOTICE_TEXT = "----- NOTICE TEXT -----"
END_NOTICE = "----- END COMPONENT NOTICE -----"
SHA256 = re.compile(r"^[0-9a-f]{64}$")
SPDX_EXPRESSION = re.compile(
    r"^(?:Apache-2\.0|BSD-3-Clause|LGPL-2\.1-only)"
    r"(?: (?:AND|OR) (?:Apache-2\.0|BSD-3-Clause|LGPL-2\.1-only))*$"
)
MAX_ARCHIVE_ENTRY = 64 * 1024 * 1024
MAX_COMPRESSED_NOTICES = 16 * 1024 * 1024


class GateError(RuntimeError):
    """A release artifact failed a license invariant."""


@dataclass(frozen=True)
class ComponentEvidence:
    ecosystem: str
    name: str
    version: str
    license_expression: str
    notice_hash: str
    artifact_hashes: tuple[str, ...]


@dataclass(frozen=True)
class IosPubNotice:
    name: str
    version: str
    license_expression: str
    notice_file: str
    notice_hash: str
    archive_hash: str


def _require(condition: bool, message: str) -> None:
    if not condition:
        raise GateError(message)


def _read_entry(
    archive: zipfile.ZipFile,
    name: str,
    *,
    size_limit: int = MAX_ARCHIVE_ENTRY,
) -> bytes:
    try:
        info = archive.getinfo(name)
    except KeyError as error:
        raise GateError(f"APK is missing {name}") from error
    _require(info.file_size <= size_limit, f"APK entry is too large: {name}")
    _require(info.compress_size <= size_limit, f"APK entry is too compressed: {name}")
    _require(info.flag_bits & 0x1 == 0, f"APK entry is encrypted: {name}")
    with archive.open(info) as source:
        payload = source.read(size_limit + 1)
    _require(len(payload) <= size_limit, f"APK entry exceeded its size limit: {name}")
    return payload


def _decompress_flutter_notices(payload: bytes) -> str:
    _require(
        len(payload) <= MAX_COMPRESSED_NOTICES,
        "Flutter NOTICES.Z exceeds the compressed size limit",
    )
    try:
        with gzip.GzipFile(fileobj=io.BytesIO(payload)) as source:
            notices = source.read(MAX_ARCHIVE_ENTRY + 1)
    except (EOFError, OSError) as error:
        raise GateError("Flutter NOTICES.Z is not valid gzip data") from error
    _require(
        len(notices) <= MAX_ARCHIVE_ENTRY,
        "Flutter NOTICES.Z exceeds the decompressed size limit",
    )
    try:
        return notices.decode("utf-8")
    except UnicodeDecodeError as error:
        raise GateError("Flutter NOTICES.Z is not UTF-8") from error


def _package_blocks(lines: list[str]) -> list[tuple[str, list[str]]]:
    in_packages = False
    current_package: str | None = None
    current_lines: list[str] = []
    result: list[tuple[str, list[str]]] = []

    for line in lines:
        if line == "packages:":
            in_packages = True
            continue
        if not in_packages:
            continue
        if line and not line.startswith(" "):
            break
        package_match = re.fullmatch(r"  ([A-Za-z0-9_]+):", line)
        if package_match:
            if current_package is not None:
                result.append((current_package, current_lines))
            current_package = package_match.group(1)
            current_lines = []
            continue
        if current_package is None:
            continue
        current_lines.append(line)
    if current_package is not None:
        result.append((current_package, current_lines))
    return result


def _hosted_record(package_name: str, lines: list[str]) -> tuple[str, str] | None:
    fields: dict[str, str] = {}
    for line in lines:
        match = re.fullmatch(r"\s+(source|version|sha256):\s*(.+)", line)
        if match:
            fields[match.group(1)] = match.group(2).strip('"')
    if fields.get("source") != "hosted":
        return None
    version = fields.get("version")
    archive_sha256 = fields.get("sha256")
    _require(version is not None, f"Hosted package has no version: {package_name}")
    _require(
        archive_sha256 is not None and SHA256.fullmatch(archive_sha256),
        f"Hosted package has no valid SHA-256: {package_name}",
    )
    return version, archive_sha256


def hosted_package_records(lockfile: Path) -> dict[str, tuple[str, str]]:
    try:
        lines = lockfile.read_text(encoding="utf-8").splitlines()
    except OSError as error:
        raise GateError(f"Cannot read lockfile: {lockfile}") from error

    result = {
        package_name: record
        for package_name, package_lines in _package_blocks(lines)
        if (record := _hosted_record(package_name, package_lines)) is not None
    }
    _require(result, "Lockfile does not contain any hosted packages")
    return result


def hosted_packages(lockfile: Path) -> set[str]:
    return set(hosted_package_records(lockfile))


def ios_pub_notices(manifest: Path) -> dict[str, IosPubNotice]:
    try:
        payload = manifest.read_bytes()
    except OSError as error:
        raise GateError(f"Cannot read iOS Pub notice manifest: {manifest}") from error
    _require(len(payload) <= 64 * 1024, "iOS Pub notice manifest is too large")
    try:
        lines = payload.decode("utf-8").splitlines()
    except UnicodeDecodeError as error:
        raise GateError("iOS Pub notice manifest is not UTF-8") from error

    result: dict[str, IosPubNotice] = {}
    for line_number, line in enumerate(lines, start=1):
        if not line or line.startswith("#"):
            continue
        fields = line.split("\t")
        _require(
            len(fields) == 6,
            f"Invalid iOS Pub notice manifest row {line_number}",
        )
        name, version, license_expression, notice_file, notice_hash, archive_hash = fields
        _require(
            re.fullmatch(r"[A-Za-z0-9_]+", name) is not None,
            f"Invalid iOS Pub package name: {name}",
        )
        _require(name not in result, f"Duplicate iOS Pub notice: {name}")
        _require(bool(version), f"Missing iOS Pub package version: {name}")
        _require(
            SPDX_EXPRESSION.fullmatch(license_expression) is not None,
            f"Invalid iOS Pub SPDX expression: {name}",
        )
        _require(
            re.fullmatch(r"[A-Za-z0-9._-]+", notice_file) is not None,
            f"Invalid iOS Pub notice file: {name}",
        )
        _require(
            SHA256.fullmatch(notice_hash) is not None,
            f"Invalid iOS Pub notice hash: {name}",
        )
        _require(
            SHA256.fullmatch(archive_hash) is not None,
            f"Invalid iOS Pub archive hash: {name}",
        )
        result[name] = IosPubNotice(
            name=name,
            version=version,
            license_expression=license_expression,
            notice_file=notice_file,
            notice_hash=notice_hash,
            archive_hash=archive_hash,
        )
    return result


def platform_expected_packages(
    records: dict[str, tuple[str, str]],
    plugin_dependencies: Path,
    platform: str,
) -> set[str]:
    try:
        document = json.loads(plugin_dependencies.read_text(encoding="utf-8"))
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as error:
        raise GateError(f"Cannot read Flutter plugin metadata: {plugin_dependencies}") from error
    plugins = document.get("plugins") if isinstance(document, dict) else None
    _require(isinstance(plugins, dict), "Flutter plugin metadata has no plugins object")
    target_plugins: set[str] = set()
    platform_plugins: set[str] = set()
    for platform_name, entries in plugins.items():
        _require(isinstance(entries, list), f"Invalid Flutter plugin list: {platform_name}")
        for entry in entries:
            _require(isinstance(entry, dict), f"Invalid Flutter plugin entry: {platform_name}")
            name = entry.get("name")
            _require(
                isinstance(name, str) and name,
                f"Flutter plugin has no name: {platform_name}",
            )
            platform_plugins.add(name)
            if platform_name == platform:
                target_plugins.add(name)
    non_target_plugins = platform_plugins - target_plugins
    return set(records) - non_target_plugins


def android_expected_packages(
    records: dict[str, tuple[str, str]],
    plugin_dependencies: Path,
) -> set[str]:
    return platform_expected_packages(records, plugin_dependencies, "android")


def flutter_notice_packages(notices: str) -> set[str]:
    package_names: set[str] = set()
    for section in notices.split(NOTICE_SEPARATOR):
        lines = section.strip().splitlines()
        for line in lines:
            name = line.strip()
            if not name:
                break
            if re.fullmatch(r"[A-Za-z0-9_]+", name):
                package_names.add(name)
    return package_names


def _nonempty_string(value: Any, field: str) -> str:
    _require(isinstance(value, str) and bool(value.strip()), f"Invalid {field}")
    return value


def _validate_license_ids(component: dict[str, Any], coordinate: str) -> list[str]:
    licenses = component.get("licenses")
    _require(isinstance(licenses, list) and licenses, f"Missing licenses: {coordinate}")
    result: list[str] = []
    for license_entry in licenses:
        _require(isinstance(license_entry, dict), f"Invalid license entry: {coordinate}")
        expression = license_entry.get("expression")
        if expression is not None:
            license_id = _nonempty_string(expression, "SPDX license expression")
        else:
            license_object = license_entry.get("license")
            _require(isinstance(license_object, dict), f"Invalid license object: {coordinate}")
            license_id = _nonempty_string(license_object.get("id"), "SPDX license id")
        normalized = license_id.upper()
        _require(
            normalized not in {"NOASSERTION", "NONE"} and "UNKNOWN" not in normalized,
            f"Unknown SPDX license: {coordinate}",
        )
        _require(
            SPDX_EXPRESSION.fullmatch(license_id) is not None,
            f"Unsupported SPDX license expression: {coordinate}",
        )
        result.append(license_id)
    return result


def _notice_hash(component: dict[str, Any], coordinate: str) -> str:
    properties = component.get("properties")
    _require(isinstance(properties, list), f"Missing properties: {coordinate}")
    values = [
        item.get("value")
        for item in properties
        if isinstance(item, dict) and item.get("name") == NOTICE_HASH_PROPERTY
    ]
    _require(len(values) == 1, f"Missing or duplicate notice hash: {coordinate}")
    value = values[0]
    _require(isinstance(value, str) and SHA256.fullmatch(value), f"Invalid notice hash: {coordinate}")
    return value


def validate_sbom(payload: bytes) -> dict[str, ComponentEvidence]:
    try:
        document = json.loads(payload.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise GateError("SBOM.json is not valid UTF-8 JSON") from error
    _require(isinstance(document, dict), "SBOM root must be an object")
    _require(document.get("bomFormat") == "CycloneDX", "SBOM format is not CycloneDX")
    _require(document.get("specVersion") == "1.6", "SBOM version is not 1.6")
    components = document.get("components")
    _require(isinstance(components, list) and components, "SBOM has no components")

    result: dict[str, ComponentEvidence] = {}
    for component in components:
        _require(isinstance(component, dict), "SBOM component must be an object")
        group = _nonempty_string(component.get("group"), "component group")
        name = _nonempty_string(component.get("name"), "component name")
        version = _nonempty_string(component.get("version"), "component version")
        purl = component.get("purl")
        maven_purl = f"pkg:maven/{group}/{name}@{version}"
        pub_purl = f"pkg:pub/{name}@{version}"
        if purl == maven_purl:
            ecosystem = "maven"
            coordinate = f"{group}:{name}:{version}"
        elif group == "pub.dev" and purl == pub_purl:
            ecosystem = "pub"
            coordinate = f"pub:{name}:{version}"
        else:
            raise GateError(f"Invalid purl: {group}:{name}:{version}")
        _require(coordinate not in result, f"Duplicate SBOM component: {coordinate}")

        hashes = component.get("hashes")
        _require(isinstance(hashes, list) and hashes, f"Missing artifact hashes: {coordinate}")
        artifact_hash_values: list[str] = []
        for artifact_hash in hashes:
            _require(isinstance(artifact_hash, dict), f"Invalid artifact hash: {coordinate}")
            content = artifact_hash.get("content")
            _require(
                artifact_hash.get("alg") == "SHA-256"
                and isinstance(content, str)
                and SHA256.fullmatch(content),
                f"Invalid artifact SHA-256: {coordinate}",
            )
            artifact_hash_values.append(content)

        licenses = _validate_license_ids(component, coordinate)
        _require(len(licenses) == 1, f"Expected one SPDX license: {coordinate}")
        result[coordinate] = ComponentEvidence(
            ecosystem=ecosystem,
            name=name,
            version=version,
            license_expression=licenses[0],
            notice_hash=_notice_hash(component, coordinate),
            artifact_hashes=tuple(artifact_hash_values),
        )
    return result


def validate_third_party_notices(
    payload: bytes,
    components: dict[str, ComponentEvidence],
) -> None:
    try:
        notices = payload.decode("utf-8")
    except UnicodeDecodeError as error:
        raise GateError("THIRD_PARTY_NOTICES.txt is not UTF-8") from error
    _require(notices.startswith("Third-party notices for Android release runtime dependencies\n"), "Invalid third-party notice header")

    covered: set[str] = set()
    sections = notices.split(BEGIN_NOTICE)[1:]
    _require(sections, "Third-party notices contain no component sections")
    for section in sections:
        _require(section.count(END_NOTICE) == 1, "Malformed third-party notice section")
        body, trailer = section.split(END_NOTICE, 1)
        _require(not trailer.strip(), "Unexpected data after third-party notice section")
        _require(NOTICE_TEXT in body, "Third-party notice section has no notice text")
        metadata, notice_text = body.lstrip("\n").split(f"{NOTICE_TEXT}\n", 1)
        component_lines = [
            line.removeprefix("Component: ")
            for line in metadata.splitlines()
            if line.startswith("Component: ")
        ]
        license_lines = [
            line.removeprefix("License: ")
            for line in metadata.splitlines()
            if line.startswith("License: ")
        ]
        hash_lines = [
            line.removeprefix("Notice-SHA256: ")
            for line in metadata.splitlines()
            if line.startswith("Notice-SHA256: ")
        ]
        size_lines = [
            line.removeprefix("Notice-Bytes: ")
            for line in metadata.splitlines()
            if line.startswith("Notice-Bytes: ")
        ]
        _require(component_lines, "Third-party notice section has no components")
        _require(len(license_lines) == 1, "Third-party notice section has an invalid license")
        _require(len(hash_lines) == 1 and SHA256.fullmatch(hash_lines[0]), "Third-party notice section has an invalid hash")
        _require(
            len(size_lines) == 1 and size_lines[0].isdigit(),
            "Third-party notice section has an invalid byte count",
        )
        notice_bytes = notice_text.encode("utf-8")
        notice_size = int(size_lines[0])
        _require(notice_size <= len(notice_bytes), "Third-party notice text is truncated")
        exact_notice = notice_bytes[:notice_size]
        _require(
            notice_bytes[notice_size:] in {b"", b"\n"},
            "Unexpected data after third-party notice text",
        )
        actual_hash = hashlib.sha256(exact_notice).hexdigest()
        _require(actual_hash == hash_lines[0], "Third-party notice text hash mismatch")

        for coordinate in component_lines:
            _require(coordinate in components, f"Notice covers unknown component: {coordinate}")
            _require(coordinate not in covered, f"Duplicate notice coverage: {coordinate}")
            evidence = components[coordinate]
            _require(
                license_lines[0] == evidence.license_expression,
                f"Notice license mismatch: {coordinate}",
            )
            _require(hash_lines[0] == evidence.notice_hash, f"Notice hash mismatch: {coordinate}")
            covered.add(coordinate)

    missing = set(components) - covered
    _require(not missing, f"Missing third-party notices: {', '.join(sorted(missing))}")


def validate_apk(
    apk: Path,
    lockfile: Path,
    plugin_dependencies: Path | None = None,
) -> dict[str, int]:
    try:
        with zipfile.ZipFile(apk) as archive:
            flutter_payload = _read_entry(
                archive,
                FLUTTER_NOTICES,
                size_limit=MAX_COMPRESSED_NOTICES,
            )
            sbom_payload = _read_entry(archive, SBOM)
            third_party_payload = _read_entry(archive, THIRD_PARTY_NOTICES)
    except (OSError, zipfile.BadZipFile) as error:
        raise GateError(f"Cannot read APK: {apk}") from error

    records = hosted_package_records(lockfile)
    plugins_file = plugin_dependencies or lockfile.parent / ".flutter-plugins-dependencies"
    expected_packages = android_expected_packages(records, plugins_file)
    notice_packages = flutter_notice_packages(_decompress_flutter_notices(flutter_payload))
    missing_packages = expected_packages - notice_packages
    components = validate_sbom(sbom_payload)
    pub_components = {
        evidence.name: evidence
        for evidence in components.values()
        if evidence.ecosystem == "pub"
    }
    for package_name, evidence in pub_components.items():
        _require(package_name in records, f"SBOM covers unknown Pub package: {package_name}")
        locked_version, locked_sha256 = records[package_name]
        _require(evidence.version == locked_version, f"Pub package version mismatch: {package_name}")
        _require(
            locked_sha256 in evidence.artifact_hashes,
            f"Pub package archive hash mismatch: {package_name}",
        )
    unnecessary_pub_components = set(pub_components) - missing_packages
    _require(
        not unnecessary_pub_components,
        "SBOM redundantly covers Flutter-noticed Pub packages: "
        f"{', '.join(sorted(unnecessary_pub_components))}",
    )
    uncovered_packages = missing_packages - set(pub_components)
    _require(
        not uncovered_packages,
        f"Flutter notices miss hosted packages: {', '.join(sorted(uncovered_packages))}",
    )
    validate_third_party_notices(third_party_payload, components)
    return {
        "flutter_packages": len(expected_packages),
        "android_components": len(components),
    }


def _ios_app_payloads(
    artifact: Path,
    resources: set[str],
) -> dict[str, bytes]:
    if artifact.is_dir():
        result: dict[str, bytes] = {}
        for resource in resources:
            source = artifact / resource
            try:
                size = source.stat().st_size
                limit = (
                    MAX_COMPRESSED_NOTICES
                    if resource == IOS_FLUTTER_NOTICES
                    else MAX_ARCHIVE_ENTRY
                )
                _require(size <= limit, f"iOS resource exceeds the size limit: {resource}")
                result[resource] = source.read_bytes()
            except OSError as error:
                raise GateError(f"Cannot read iOS resource: {resource}") from error
        return result

    try:
        with zipfile.ZipFile(artifact) as archive:
            suffix = f".app/{IOS_FLUTTER_NOTICES}"
            candidates = [name for name in archive.namelist() if name.endswith(suffix)]
            _require(len(candidates) == 1, "iOS archive must contain exactly one app NOTICES.Z")
            app_prefix = candidates[0][: -len(IOS_FLUTTER_NOTICES)]
            return {
                resource: _read_entry(
                    archive,
                    f"{app_prefix}{resource}",
                    size_limit=(
                        MAX_COMPRESSED_NOTICES
                        if resource == IOS_FLUTTER_NOTICES
                        else MAX_ARCHIVE_ENTRY
                    ),
                )
                for resource in resources
            }
    except (OSError, zipfile.BadZipFile) as error:
        raise GateError(f"Cannot read iOS release artifact: {artifact}") from error


def validate_ios_app(
    artifact: Path,
    lockfile: Path,
    plugin_dependencies: Path | None = None,
    pub_notice_manifest: Path | None = None,
) -> dict[str, int]:
    records = hosted_package_records(lockfile)
    plugins_file = plugin_dependencies or lockfile.parent / ".flutter-plugins-dependencies"
    manifest = pub_notice_manifest or lockfile.parent / "ios/release-licenses/pub-components.tsv"
    manual_notices = ios_pub_notices(manifest)
    payloads = _ios_app_payloads(
        artifact,
        {IOS_FLUTTER_NOTICES, *(notice.notice_file for notice in manual_notices.values())},
    )
    expected_packages = platform_expected_packages(records, plugins_file, "ios")
    notice_packages = flutter_notice_packages(
        _decompress_flutter_notices(payloads[IOS_FLUTTER_NOTICES])
    )
    missing_packages = expected_packages - notice_packages
    redundant_packages = set(manual_notices) - missing_packages
    _require(
        not redundant_packages,
        "iOS manifest redundantly covers Flutter-noticed Pub packages: "
        f"{', '.join(sorted(redundant_packages))}",
    )
    uncovered_packages = missing_packages - set(manual_notices)
    _require(
        not uncovered_packages,
        f"Flutter notices miss hosted packages: {', '.join(sorted(uncovered_packages))}",
    )
    for package_name, notice in manual_notices.items():
        _require(package_name in records, f"iOS manifest covers unknown Pub package: {package_name}")
        locked_version, locked_archive_hash = records[package_name]
        _require(
            notice.version == locked_version,
            f"iOS Pub package version mismatch: {package_name}",
        )
        _require(
            notice.archive_hash == locked_archive_hash,
            f"iOS Pub package archive hash mismatch: {package_name}",
        )
        notice_payload = payloads[notice.notice_file]
        try:
            notice_payload.decode("utf-8")
        except UnicodeDecodeError as error:
            raise GateError(f"iOS Pub notice is not UTF-8: {package_name}") from error
        _require(bool(notice_payload), f"iOS Pub notice is empty: {package_name}")
        _require(
            hashlib.sha256(notice_payload).hexdigest() == notice.notice_hash,
            f"iOS Pub notice hash mismatch: {package_name}",
        )
    return {
        "flutter_packages": len(expected_packages),
        "ios_components": len(manual_notices),
    }


def _parse_args(argv: list[str]) -> argparse.Namespace:
    mobile_root = Path(__file__).resolve().parent.parent
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("artifact", type=Path, help="Release APK, IPA, or .app to validate")
    parser.add_argument(
        "--platform",
        choices=("android", "ios"),
        default="android",
        help="Target release platform",
    )
    parser.add_argument(
        "--lockfile",
        type=Path,
        default=mobile_root / "pubspec.lock",
        help="Flutter pubspec.lock used for the release build",
    )
    parser.add_argument(
        "--plugins",
        type=Path,
        default=mobile_root / ".flutter-plugins-dependencies",
        help="Flutter platform-plugin metadata used for the release build",
    )
    parser.add_argument(
        "--ios-pub-components",
        type=Path,
        default=mobile_root / "ios/release-licenses/pub-components.tsv",
        help="Locked iOS Pub components omitted from Flutter NOTICES.Z",
    )
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = _parse_args(sys.argv[1:] if argv is None else argv)
    try:
        counts = (
            validate_apk(args.artifact, args.lockfile, args.plugins)
            if args.platform == "android"
            else validate_ios_app(
                args.artifact,
                args.lockfile,
                args.plugins,
                args.ios_pub_components,
            )
        )
    except GateError as error:
        print(f"release-license gate failed: {error}", file=sys.stderr)
        return 1
    print(
        "release-license gate passed: "
        f"{counts['flutter_packages']} Flutter packages"
        + (
            f", {counts['android_components']} Android runtime components"
            if args.platform == "android"
            else f", {counts['ios_components']} iOS native Pub components"
        )
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
