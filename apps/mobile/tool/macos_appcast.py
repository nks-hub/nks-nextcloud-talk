"""Create the signed appcast uploaded beside a notarized macOS release ZIP."""

import argparse
import plistlib
import shutil
import subprocess
import tempfile
import zipfile
from pathlib import Path
from urllib.parse import quote


def release_tag(info: dict, expected_key: str) -> str:
    if info.get("CFBundleIdentifier") != "com.nkshub.nextcloudtalk":
        raise ValueError("The archive is not an OwnTalk application")
    if info.get("SUPublicEDKey") != expected_key:
        raise ValueError("The archive does not contain the release public key")
    if not info.get("SUVerifyUpdateBeforeExtraction") or not info.get("SURequireSignedFeed"):
        raise ValueError("The archive does not require signed updates and feeds")
    version = info["CFBundleShortVersionString"]
    build = info["CFBundleVersion"]
    if not isinstance(build, str) or not build.isdecimal():
        raise ValueError("The archive has an invalid build number")
    return f"v{version}+{build}"


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("archive", type=Path)
    args = parser.parse_args()
    mobile = Path(__file__).resolve().parents[1]
    tools = mobile / "macos/Pods/Sparkle/bin"
    archive = args.archive.resolve(strict=True)
    expected = plistlib.loads((mobile / "macos/Runner/Info.plist").read_bytes())
    with zipfile.ZipFile(archive) as zipped:
        info = plistlib.loads(zipped.read("nextcloudtalk.app/Contents/Info.plist"))
    tag = release_tag(info, expected["SUPublicEDKey"])
    if archive.name != f"nks-talk-macos-{info['CFBundleShortVersionString']}-{info['CFBundleVersion']}.zip":
        raise ValueError("The archive filename does not match its version")
    output = archive.with_name("appcast.xml")
    account = "com.nkshub.nextcloudtalk"
    with tempfile.TemporaryDirectory(prefix="owntalk-appcast-") as staging:
        shutil.copy2(archive, Path(staging) / archive.name)
        generated = Path(staging) / "appcast.xml"
        subprocess.run([
            str(tools / "generate_appcast"), "--account", account,
            "--maximum-deltas", "0", "--download-url-prefix",
            f"https://github.com/nks-hub/nks-nextcloud-talk/releases/download/{quote(tag, safe='')}/",
            "-o", str(generated), staging,
        ], check=True)
        subprocess.run([
            str(tools / "sign_update"), "--account", account, "--verify", str(generated),
        ], check=True)
        shutil.copy2(generated, output)
    print(f"Upload {archive.name} and {output.name} to {tag}")


if __name__ == "__main__":
    main()
