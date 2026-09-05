#!/usr/bin/env python3
"""Fails when a tracked text file names operator infrastructure (CONTRIBUTING.md).

Generic patterns only. The operator's own literal hosts and machine names live
in a gitignored `.public-denylist` (one literal per line) and are checked only
where that file exists — this file is public too.
"""
import os
import re
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SKIP = (".png", ".jpg", ".jpeg", ".gif", ".ico", ".icns", ".ttf", ".otf", ".woff", ".woff2",
        ".zip", ".jar", ".bin", ".so", ".dll", ".exe", ".mp3", ".m4a", ".wav", ".pdf", ".g.dart",
        "pubspec.lock", "Podfile.lock", "emoji_czech_names.g.dart")
# Fixture domains (RFC 2606/6761), tester lists, GitHub no-reply and the upstream QR-login fixture.
ALLOWED_MAIL = re.compile(r"@(?:[a-z0-9-]+\.)*(?:example|invalid|test|localhost|local|example\.(?:com|org|net)|googlegroups\.com|users\.noreply\.github\.com)$|^test@user\.com$", re.I)
IMAGE_TLD = re.compile(r"\.(?:png|jpe?g|webp|svg|gif)$", re.I)
PATTERNS = [
    ("private IPv4", re.compile(r"\b(?:10\.\d{1,3}\.\d{1,3}\.\d{1,3}|192\.168\.\d{1,3}\.\d{1,3}|172\.(?:1[6-9]|2\d|3[01])\.\d{1,3}\.\d{1,3})\b")),
    # Generic account names used by fixtures and hosted CI are not operator paths.
    ("home path", re.compile(r"(?:/Users/|/home/)(?!(?:user|builder|runner)\b)[a-z][a-z0-9_-]*\b|C:\\Users\\(?!(?:runneradmin|user)\\)[A-Za-z]")),
    ("sudo -u user", re.compile(r"sudo -u (?!<)[A-Za-z]")),
    ("Apple team id", re.compile(r"DEVELOPMENT_TEAM = [A-Z0-9]{10}\b")),
    ("signing identity", re.compile(r"Developer ID Application: [^$<\"]")),
]
MARKDOWN_PATTERNS = [
    ("24-hex id in docs", re.compile(r"(?<![0-9a-f])[0-9a-f]{24}(?![0-9a-f])")),
]
# The IP bogon lists in the gateway's own policy code are the one legitimate home of private ranges.
EXEMPT = ("services/push_gateway/internal/identityproof/", "tool/public_repo_gate.py", "CONTRIBUTING.md")


def tracked():
    out = subprocess.check_output(["git", "ls-files", "-z"], cwd=ROOT)
    return [p for p in out.decode("utf-8").split("\0") if p]


def main():
    denylist = []
    deny_path = os.path.join(ROOT, ".public-denylist")
    if os.path.exists(deny_path):
        denylist = [l.strip() for l in io_open(deny_path) if l.strip() and not l.startswith("#")]
    findings = []
    for rel in tracked():
        if rel.endswith(SKIP) or rel.startswith(EXEMPT):
            continue
        try:
            text = io_open(os.path.join(ROOT, rel)).read()
        except (OSError, UnicodeDecodeError):
            continue
        checks = list(PATTERNS)
        if rel.endswith(".md"):
            checks += MARKDOWN_PATTERNS
        for number, line in enumerate(text.splitlines(), 1):
            for name, pattern in checks:
                if pattern.search(line):
                    findings.append((rel, number, name))
            for mail in re.findall(r"(?<![\w@])[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,6}(?![\w@])", line):
                # Kotlin `this@label.call` and `name@2x.png` are not addresses.
                if IMAGE_TLD.search(mail) or re.search(r"@\w+\.\w*[A-Z]", mail):
                    continue
                if not ALLOWED_MAIL.search(mail):
                    findings.append((rel, number, "e-mail address"))
            for literal in denylist:
                if literal in line:
                    findings.append((rel, number, "denylisted literal"))
    for rel, number, name in findings:
        print(f"{rel}:{number}: {name}")
    print(f"public repository gate: {len(findings)} finding(s)")
    return 1 if findings else 0


def io_open(p):
    return open(p, encoding="utf-8")


if __name__ == "__main__":
    sys.exit(main())
