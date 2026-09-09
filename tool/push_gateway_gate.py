#!/usr/bin/env python3
"""Refuses a distributable build whose push gateway is missing or wrong.

Build 65 was nearly cut with a `telemetry.env` that carried four telemetry
values and no `PUSH_GATEWAY_ORIGIN`. Nothing failed: the application compiles
without it and quietly registers for push nowhere, so the mistake would only
have shown up as devices that never ring. Two checks close that, and the
release runs both:

    push_gateway_gate.py defines --origin https://gateway.example \\
        --define-file telemetry.env [--define PUSH_GATEWAY_ORIGIN=…]
    push_gateway_gate.py artifact --origin https://gateway.example app.apk

The first reads what the build is about to be given, the second reads what the
build actually produced — the compiled Dart, where a define that never reached
the compiler cannot hide. Neither knows any operator host: the expected origin
is always an argument, because this file is public.
"""
import argparse
import os
import re
import sys
import zipfile
from urllib.parse import urlsplit

DEFINE_NAME = "PUSH_GATEWAY_ORIGIN"

# Where the compiled Dart of each distributable format keeps its constants.
AOT_MEMBERS = (
    re.compile(r"^lib/[^/]+/libapp\.so$"),  # Android APK
    re.compile(r"^base/lib/[^/]+/libapp\.so$"),  # Android app bundle
    re.compile(r"^Payload/[^/]+\.app/Frameworks/App\.framework/App$"),  # iOS IPA
)

# The desktop snapshots. `PUSH_GATEWAY_ORIGIN` is read inside the Apple branch
# of app_providers_push.dart, so the AOT compiler drops the string from a
# Windows or Linux build and the gate would report a perfectly good artifact as
# missing its origin.
DESKTOP_MEMBERS = (
    re.compile(r"(^|[\\/])data[\\/]app\.so$"),  # Windows runner
    re.compile(r"(^|[\\/])lib[\\/]libapp\.so$"),  # Linux bundle
)


class GateError(Exception):
    """A build that must not be distributed."""


def valid_origin(value):
    """An https origin and nothing else: no path, query, fragment or userinfo.

    A gateway with a path silently produces registration URLs that resolve
    somewhere else, which is the same failure as having no gateway at all,
    only harder to see.
    """
    if not value or value.strip() != value:
        return False
    parts = urlsplit(value)
    return (
        parts.scheme == "https"
        and bool(parts.hostname)
        and "@" not in parts.netloc
        and parts.path in ("", "/")
        and not parts.query
        and not parts.fragment
    )


def read_define_file(path):
    defines = {}
    with open(path, encoding="utf-8") as handle:
        for number, raw in enumerate(handle, start=1):
            line = raw.strip()
            if not line or line.startswith("#"):
                continue
            if "=" not in line:
                raise GateError(f"{path}:{number}: not a KEY=VALUE line")
            key, value = line.split("=", 1)
            defines[key.strip()] = value.strip()
    return defines


def check_defines(origin, define_files, defines):
    found = {}
    for path in define_files:
        found.update(read_define_file(path))
    for item in defines:
        if "=" not in item:
            raise GateError(f"--define {item!r} is not KEY=VALUE")
        key, value = item.split("=", 1)
        found[key] = value
    actual = found.get(DEFINE_NAME)
    if actual is None:
        raise GateError(
            f"{DEFINE_NAME} is not among the build defines "
            f"({', '.join(sorted(found)) or 'none given'}); this build would "
            "register for push nowhere"
        )
    if not valid_origin(actual):
        raise GateError(f"{DEFINE_NAME} is not a bare https origin")
    if actual != origin:
        raise GateError(f"{DEFINE_NAME} is not the origin this release expects")
    return actual


def desktop_artifact(path):
    """Whether this snapshot belongs to a platform that never registers."""
    return any(pattern.search(path) for pattern in DESKTOP_MEMBERS)


def check_artifact(origin, path):
    if not valid_origin(origin):
        raise GateError("--origin is not a bare https origin")
    needle = origin.encode()
    if not zipfile.is_zipfile(path):
        with open(path, "rb") as handle:
            if needle in handle.read():
                return os.path.basename(path)
        raise GateError(f"{path} does not carry the expected gateway origin")
    with zipfile.ZipFile(path) as archive:
        members = [
            name
            for name in archive.namelist()
            if any(pattern.match(name) for pattern in AOT_MEMBERS)
        ]
        if not members:
            raise GateError(f"{path} holds no compiled Dart to check")
        for name in members:
            if needle not in archive.read(name):
                raise GateError(f"{name} does not carry the expected gateway origin")
        return ", ".join(members)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--origin", required=True)
    sub = parser.add_subparsers(dest="mode", required=True)
    defines = sub.add_parser("defines")
    defines.add_argument("--define-file", action="append", default=[])
    defines.add_argument("--define", action="append", default=[])
    artifact = sub.add_parser("artifact")
    artifact.add_argument("path")
    args = parser.parse_args(argv)
    try:
        if args.mode == "defines":
            check_defines(args.origin, args.define_file, args.define)
            print(f"{DEFINE_NAME} present and expected")
        else:
            if desktop_artifact(args.path):
                print(
                    f"{DEFINE_NAME} is not compiled into a desktop build and "
                    "is not expected to be: only iOS and macOS register with "
                    "the gateway, so the compiler drops the constant"
                )
                return 0
            where = check_artifact(args.origin, args.path)
            print(f"{DEFINE_NAME} compiled into {where}")
    except (GateError, OSError) as failure:
        print(f"push gateway gate: {failure}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
