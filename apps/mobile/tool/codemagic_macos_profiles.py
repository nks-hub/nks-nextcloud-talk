"""Embed Developer ID profiles and resolve the macOS signing entitlements."""

import hashlib
import plistlib
import shutil
import subprocess
import sys
from datetime import datetime
from pathlib import Path


def read_plist(path):
    return plistlib.loads(path.read_bytes())


def main():
    app, team, identity = Path(sys.argv[1]), sys.argv[2], sys.argv[3].lower()
    profile_dir = Path.home() / "Library/Developer/Xcode/UserData/Provisioning Profiles"
    profiles = {}
    for path in profile_dir.glob("*.provisionprofile"):
        profile = plistlib.loads(subprocess.check_output(["security", "cms", "-D", "-i", path]))
        if not profile.get("ProvisionsAllDevices") or profile["ExpirationDate"] <= datetime.utcnow():
            continue
        if not any(hashlib.sha1(cert).hexdigest() == identity for cert in profile["DeveloperCertificates"]):
            continue
        app_id = profile["Entitlements"].get("com.apple.application-identifier")
        if app_id and (app_id not in profiles or profile["CreationDate"] > profiles[app_id][0]):
            profiles[app_id] = (profile["CreationDate"], path)

    extension = app / "Contents/PlugIns/NotificationServiceExtension.appex"
    for bundle, source, target in (
        (app, "macos/Runner/Release.entitlements", "/tmp/owntalk-app.entitlements"),
        (
            extension,
            "macos/NotificationServiceExtension/NotificationServiceExtension.entitlements",
            "/tmp/owntalk-appex.entitlements",
        ),
    ):
        contents = bundle / "Contents"
        bundle_id = read_plist(contents / "Info.plist")["CFBundleIdentifier"]
        app_id = f"{team}.{bundle_id}"
        if app_id not in profiles:
            raise SystemExit(f"No active Developer ID profile for {bundle_id} matches the signing certificate")
        shutil.copyfile(profiles[app_id][1], contents / "embedded.provisionprofile")
        raw = Path(source).read_bytes()
        entitlements = plistlib.loads(
            raw.replace(b"$(APS_ENVIRONMENT)", b"production")
            .replace(b"$(AppIdentifierPrefix)", f"{team}.".encode())
        )
        entitlements["com.apple.application-identifier"] = app_id
        entitlements["com.apple.developer.team-identifier"] = team
        Path(target).write_bytes(plistlib.dumps(entitlements))


if __name__ == "__main__":
    main()
