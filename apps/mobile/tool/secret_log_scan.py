#!/usr/bin/env python3
"""Scan tracked source and explicit artifacts without disclosing secret values."""

from __future__ import annotations

import argparse
import re
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable, Iterator, Sequence


MAX_LINE_BYTES = 1024 * 1024
CHUNK_OVERLAP = 256

PRIVATE_KEY = re.compile(
    r"-----BEGIN (?:RSA |EC |OPENSSH |DSA )?PRIVATE KEY-----"
)
PROVIDER_TOKEN = re.compile(
    r"(?:"
    r"AKIA[0-9A-Z]{16}"
    r"|gh[pousr]_[A-Za-z0-9]{36,}"
    r"|github_pat_[A-Za-z0-9_]{40,}"
    r"|xox[baprs]-[A-Za-z0-9-]{20,}"
    r"|SG\.[A-Za-z0-9_-]{16,}\.[A-Za-z0-9_-]{16,}"
    r")"
)
CREDENTIAL_ASSIGNMENT = re.compile(
    r"(?ix)\b(?:"
    r"password|passwd|app[_-]?password|api[_-]?key|client[_-]?secret|"
    r"access[_-]?token|refresh[_-]?token|auth[_-]?token|secret|token"
    r")\b\s*[=:]\s*(?P<value>[^\s,;#]+)"
)
AUTHORIZATION = re.compile(
    r"(?i)\bauthorization\s*:\s*(?P<value>.+)$"
)
COOKIE = re.compile(r"(?i)\b(?:set-cookie|cookie)\s*:\s*(?P<value>.+)$")
SAFE_VALUE_MARKERS = (
    "${",
    "{{",
    "<redacted",
    "<secret",
    "<token",
    "placeholder",
    "changeme",
    "example",
    "dummy",
    "redacted",
    "string.fromenvironment",
    "platform.environment",
)


class ScanError(RuntimeError):
    """The scan could not be completed safely."""


@dataclass(frozen=True, order=True)
class Finding:
    path: str
    line_number: int
    rule_id: str

    def render(self) -> str:
        return f"{self.path}:{self.line_number}:{self.rule_id}"


def _repository_root(root: Path) -> Path:
    requested = root.resolve()
    try:
        result = subprocess.run(
            ["git", "-C", str(requested), "rev-parse", "--show-toplevel"],
            check=True,
            capture_output=True,
            text=True,
        )
    except (OSError, subprocess.CalledProcessError) as error:
        raise ScanError(f"Not a Git repository: {requested}") from error
    actual = Path(result.stdout.strip()).resolve()
    if actual != requested:
        raise ScanError(f"Root is not the repository top level: {requested}")
    return actual


def _tracked_files(root: Path) -> list[Path]:
    try:
        result = subprocess.run(
            ["git", "-C", str(root), "ls-files", "-z"],
            check=True,
            capture_output=True,
        )
    except (OSError, subprocess.CalledProcessError) as error:
        raise ScanError(f"Cannot list tracked files under {root}") from error
    return [
        root / Path(item.decode("utf-8", errors="surrogateescape"))
        for item in result.stdout.split(b"\0")
        if item
    ]


def _artifact_files(artifacts: Iterable[Path]) -> Iterator[Path]:
    for artifact in artifacts:
        resolved = artifact.resolve()
        if not resolved.exists():
            raise ScanError(f"Artifact does not exist: {resolved}")
        if resolved.is_file():
            yield resolved
            continue
        if not resolved.is_dir():
            raise ScanError(f"Artifact is not a file or directory: {resolved}")
        for candidate in sorted(resolved.rglob("*")):
            if candidate.is_file():
                yield candidate


def _display_path(path: Path, root: Path) -> str:
    try:
        return path.resolve().relative_to(root).as_posix()
    except ValueError:
        return str(path.resolve())


def _line_chunks(path: Path) -> Iterator[tuple[int, str]]:
    try:
        with path.open("rb") as source:
            prefix = source.read(8192)
            if b"\0" in prefix:
                return
            source.seek(0)
            line_number = 1
            overlap = b""
            while chunk := source.readline(MAX_LINE_BYTES + 1):
                complete_line = chunk.endswith(b"\n")
                payload = overlap + chunk
                yield line_number, payload.decode("utf-8", errors="replace")
                overlap = b"" if complete_line else payload[-CHUNK_OVERLAP:]
                if complete_line:
                    line_number += 1
    except OSError as error:
        raise ScanError(f"Cannot read scan input: {path.resolve()}") from error


def _is_safe_value(value: str) -> bool:
    normalized = value.strip().strip("\"'").lower()
    if not normalized:
        return True
    if re.fullmatch(
        r"[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}",
        normalized,
    ):
        return True
    if normalized.startswith("$") or re.fullmatch(r"%[a-z0-9_]+%", normalized):
        return True
    return any(marker in normalized for marker in SAFE_VALUE_MARKERS)


def _normalized_value(value: str) -> str:
    normalized = value.strip().strip("\"' ,;)")
    normalized = re.sub(r"(?i)^(?:bearer|basic)\s+", "", normalized)
    return normalized


def _looks_high_confidence(value: str) -> bool:
    if _is_safe_value(value):
        return False
    normalized = _normalized_value(value)
    if len(normalized) < 20 or any(marker in normalized for marker in "${}()[]"):
        return False
    return any(character.isalpha() for character in normalized) and any(
        character.isdigit() for character in normalized
    )


def _looks_artifact_secret(value: str) -> bool:
    if _is_safe_value(value):
        return False
    normalized = _normalized_value(value)
    return len(normalized) >= 8 and not any(
        marker in normalized for marker in "${}()[]"
    )


def _rules_for_line(line: str, *, artifact: bool) -> Iterator[str]:
    if PRIVATE_KEY.search(line):
        yield "private-key"
    if PROVIDER_TOKEN.search(line):
        yield "provider-token"
    for match in CREDENTIAL_ASSIGNMENT.finditer(line):
        value = match.group("value")
        if (
            _looks_artifact_secret(value)
            if artifact
            else _looks_high_confidence(value)
        ):
            yield "credential-assignment"
            break
    authorization = AUTHORIZATION.search(line)
    if authorization and (
        _looks_artifact_secret(authorization.group("value"))
        if artifact
        else _looks_high_confidence(authorization.group("value"))
    ):
        yield "authorization-value"
    cookie = COOKIE.search(line)
    if cookie and (
        _looks_artifact_secret(cookie.group("value"))
        if artifact
        else _looks_high_confidence(cookie.group("value"))
    ):
        yield "cookie-value"


def _scan_file(path: Path, root: Path, *, artifact: bool) -> Iterator[Finding]:
    display_path = _display_path(path, root)
    for line_number, line in _line_chunks(path):
        for rule_id in _rules_for_line(line, artifact=artifact):
            yield Finding(display_path, line_number, rule_id)


def scan_repository(
    root: Path,
    *,
    artifacts: Iterable[Path] = (),
) -> list[Finding]:
    repository_root = _repository_root(root)
    inputs: dict[Path, tuple[Path, bool]] = {}
    for path in _tracked_files(repository_root):
        if path.is_file() and not path.is_symlink():
            inputs[path.resolve()] = (path, False)
    for path in _artifact_files(artifacts):
        if not path.is_symlink():
            inputs[path.resolve()] = (path, True)
    findings = {
        finding
        for resolved_path in sorted(inputs, key=lambda item: str(item).lower())
        for finding in _scan_file(
            inputs[resolved_path][0],
            repository_root,
            artifact=inputs[resolved_path][1],
        )
    }
    return sorted(findings)


def _parse_args(argv: Sequence[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--root",
        type=Path,
        default=Path(__file__).resolve().parents[3],
        help="Git repository root; defaults to this checkout",
    )
    parser.add_argument(
        "--artifact",
        action="append",
        default=[],
        type=Path,
        help="Additional build or runtime-log file/directory; repeat as needed",
    )
    return parser.parse_args(argv)


def main(argv: Sequence[str] | None = None) -> int:
    args = _parse_args(sys.argv[1:] if argv is None else argv)
    try:
        findings = scan_repository(args.root, artifacts=args.artifact)
    except ScanError as error:
        print(f"secret-log scan error: {error}", file=sys.stderr)
        return 2
    if findings:
        print("secret-log scan failed; redacted findings:", file=sys.stderr)
        for finding in findings:
            print(finding.render(), file=sys.stderr)
        return 1
    print("secret-log scan passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
