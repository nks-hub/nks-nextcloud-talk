#!/usr/bin/env python3
"""Print the CHANGELOG.md section for one release.

The release notes carry what a tester notices, and that text already exists in
the changelog. Taking it from there rather than rewriting it keeps the two from
drifting apart.
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

DEFAULT_CHANGELOG = Path(__file__).resolve().parent.parent / "CHANGELOG.md"


def parse_version(value: str) -> tuple[str, str]:
    """Split a pubspec version such as `1.0.4+70` into name and build."""
    match = re.fullmatch(r"\s*(\d+\.\d+\.\d+)\+(\d+)\s*", value)
    if match is None:
        raise ValueError(f"not a pubspec version: {value!r}")
    return match.group(1), match.group(2)


def section(text: str, name: str, build: str) -> str | None:
    """The body under `## <name> (<build>)`, or None when there is no such heading.

    Any date after the number is ignored, so a heading may be written with or
    without one.
    """
    heading = re.compile(
        rf"^## {re.escape(name)} \({re.escape(build)}\)(?: .*)?$",
        re.MULTILINE,
    )
    found = heading.search(text)
    if found is None:
        return None
    rest = text[found.end() :]
    following = re.search(r"^## ", rest, re.MULTILINE)
    body = rest if following is None else rest[: following.start()]
    return body.strip("\n")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("version", help="pubspec version, for example 1.0.4+70")
    parser.add_argument(
        "--changelog",
        type=Path,
        default=DEFAULT_CHANGELOG,
        help="path to CHANGELOG.md",
    )
    arguments = parser.parse_args(argv)

    try:
        name, build = parse_version(arguments.version)
    except ValueError as error:
        print(error, file=sys.stderr)
        return 2

    try:
        text = arguments.changelog.read_text(encoding="utf-8")
    except OSError as error:
        print(f"cannot read {arguments.changelog}: {error}", file=sys.stderr)
        return 2

    body = section(text, name, build)
    if body is None:
        print(f"no changelog section for {name} ({build})", file=sys.stderr)
        return 1

    print(body)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
