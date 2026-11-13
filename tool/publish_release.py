#!/usr/bin/env python3
"""Publishes a draft GitHub release only when every platform is in it.

CI creates the release for a `v*` tag as a draft. The Apple files come later
from the build Mac, and release 1.0.32 went out without them: the desktop
updaters read `releases/latest`, so the Mac app saw a newer build it could not
install and Windows saw nothing while its installer was missing. A draft is
never `latest`, so nothing reaches the updaters until this check passes:

    tool/publish_release.py v1.0.34+102          # check, then publish
    tool/publish_release.py v1.0.34+102 --check  # check only
"""
import argparse
import json
import re
import subprocess
import sys

REPO = "nks-hub/nks-nextcloud-talk"


def required_assets(tag: str) -> list[str]:
    match = re.fullmatch(r"v(\d+\.\d+\.\d+)\+(\d+)", tag)
    if not match:
        raise ValueError(f"not a release tag: {tag}")
    version, build = match.groups()
    return [
        "app-release.apk",
        "app-release.aab",
        f"NKS-Talk-{version}-{build}-windows-x64-setup.exe",
        "nks-talk-linux-x64.tar.gz",
        f"nks-talk-macos-{version}-{build}.zip",
        "appcast.xml",
        "SHA256SUMS",
    ]


def problems(tag: str, assets: list[str], sums: str) -> list[str]:
    """Everything that keeps the release from being complete; empty when it is."""
    found = []
    have = set(assets)
    for name in required_assets(tag):
        if name not in have:
            found.append(f"missing asset {name}")
    listed = {line.split()[-1].lstrip("*") for line in sums.splitlines() if line.strip()}
    for name in required_assets(tag):
        if name not in ("SHA256SUMS", "appcast.xml") and name in have and name not in listed:
            found.append(f"SHA256SUMS does not list {name}")
    return found


def gh(*args: str) -> str:
    return subprocess.run(["gh", *args], check=True, capture_output=True, text=True).stdout


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("tag")
    parser.add_argument("--check", action="store_true", help="only report, do not publish")
    args = parser.parse_args()
    release = json.loads(gh("release", "view", args.tag, "--repo", REPO, "--json", "assets,isDraft"))
    assets = [a["name"] for a in release["assets"]]
    sums = gh("release", "download", args.tag, "--repo", REPO, "--pattern", "SHA256SUMS", "--output", "-") \
        if "SHA256SUMS" in assets else ""
    found = problems(args.tag, assets, sums)
    for line in found:
        print(line)
    if found:
        return 1
    print(f"{args.tag}: all {len(required_assets(args.tag))} release files present")
    if args.check:
        return 0
    if release["isDraft"]:
        gh("release", "edit", args.tag, "--repo", REPO, "--draft=false", "--latest")
        print(f"{args.tag}: published as latest")
    return 0


if __name__ == "__main__":
    sys.exit(main())
