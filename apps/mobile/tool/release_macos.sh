#!/bin/bash
# Builds the macOS release ZIP for the checked-out tag: Developer ID export with
# the push and keychain profiles, notarization, stapling and the signed Sparkle
# appcast. Run from apps/mobile on the build Mac as the signed-in user, with the
# login keychain unlocked.
#
#   tool/release_macos.sh <telemetry.env> <build.env> <asc-key.p8> <key-id> <issuer> <team-id>
#
# Writes build/macos-release/nks-talk-macos-<version>-<build>.zip and appcast.xml.
set -euo pipefail

telemetry=${1:?telemetry.env}
build_env=${2:?build.env with PUSH_GATEWAY_ORIGIN}
key=${3:?App Store Connect API key}
key_id=${4:?key id}
issuer=${5:?issuer id}
team=${6:?team id}
# shellcheck disable=SC1090
source "$build_env"
: "${PUSH_GATEWAY_ORIGIN:?build.env must set PUSH_GATEWAY_ORIGIN}"
auth=(-allowProvisioningUpdates -authenticationKeyPath "$key" -authenticationKeyID "$key_id" -authenticationKeyIssuerID "$issuer")

version=$(grep '^version:' pubspec.yaml | cut -d' ' -f2)
name=${version%+*}
number=${version#*+}
out=$PWD/build/macos-release
rm -rf "$out"
mkdir -p "$out"

# Flutter writes the Dart defines into the Xcode config; Xcode then archives and
# signs. Push and the shared keychain group need a Developer ID provisioning
# profile with expanded entitlements, which only an Xcode export produces.
flutter build macos --release --config-only --dart-define-from-file="$telemetry" \
  --dart-define="PUSH_GATEWAY_ORIGIN=$PUSH_GATEWAY_ORIGIN"
xcodebuild -workspace macos/Runner.xcworkspace -scheme Runner -configuration Release \
  -destination 'generic/platform=macOS' -archivePath "$out/OwnTalk.xcarchive" archive \
  DEVELOPMENT_TEAM="$team" "${auth[@]}" 2>&1 | grep -E "error|ARCHIVE" | tail -20
test -d "$out/OwnTalk.xcarchive"

# Developer ID export with the newest installed Developer ID profile for the
# app and for its notification extension. Cloud signing is not available to
# the API key, so the profiles are named instead of left to Xcode.
python3 - "$team" "$out/export.plist" <<'PY'
import glob, os, plistlib, subprocess, sys
team, target = sys.argv[1], sys.argv[2]
best = {}
for folder in ("~/Library/MobileDevice/Provisioning Profiles", "~/Library/Developer/Xcode/UserData/Provisioning Profiles"):
    for path in glob.glob(os.path.join(os.path.expanduser(folder), "*.provisionprofile")):
        raw = subprocess.run(["security", "cms", "-D", "-i", path], capture_output=True).stdout
        if not raw:
            continue
        info = plistlib.loads(raw)
        app_id = info.get("Entitlements", {}).get("com.apple.application-identifier", "")
        if not info.get("ProvisionsAllDevices") or not app_id.startswith(team + "."):
            continue
        bundle = app_id[len(team) + 1:]
        if bundle not in best or info["CreationDate"] > best[bundle]["CreationDate"]:
            best[bundle] = info
wanted = ["com.nkshub.nextcloudtalk", "com.nkshub.nextcloudtalk.NotificationService"]
missing = [b for b in wanted if b not in best]
if missing:
    sys.exit(f"no Developer ID profile installed for {missing}")
plistlib.dump({"method": "developer-id", "signingStyle": "manual", "teamID": team,
               "signingCertificate": "Developer ID Application",
               "provisioningProfiles": {b: best[b]["UUID"] for b in wanted}}, open(target, "wb"))
for b in wanted:
    print(f"profile {b}: {best[b]['Name']}")
PY
xcodebuild -exportArchive -archivePath "$out/OwnTalk.xcarchive" -exportPath "$out/export" \
  -exportOptionsPlist "$out/export.plist" "${auth[@]}" | tail -3
app="$out/export/nextcloudtalk.app"
test -d "$app"

# Sparkle's nested installer services keep the ad-hoc signature through the
# export; re-sign them, then the app with the entitlements Xcode expanded.
# Read the whole output: grep -m1 would close the pipe early and pipefail
# would report the SIGPIPE codesign gets as a failure.
authority=$(codesign -dvv "$app" 2>&1 | grep '^Authority=Developer ID Application')
identity=${authority#Authority=}
test -n "$identity"
codesign -d --entitlements - --xml "$app" > "$out/app.entitlements"
bash tool/sign_sparkle.sh "$app" "$identity"
# Notarization rejects any executable without the hardened runtime, the
# notification extension included.
for ext in "$app"/Contents/PlugIns/*.appex; do
  /usr/bin/codesign --force --options runtime --timestamp --sign "$identity"     --preserve-metadata=entitlements "$ext"
done
/usr/bin/codesign --force --options runtime --timestamp --sign "$identity" \
  --entitlements "$out/app.entitlements" "$app"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$app"

/usr/bin/ditto -c -k --keepParent "$app" "$out/notarize.zip"
xcrun notarytool submit "$out/notarize.zip" --key "$key" --key-id "$key_id" --issuer "$issuer" --wait \
  | tee "$out/notarytool.log"
grep -q 'status: Accepted' "$out/notarytool.log"
xcrun stapler staple "$app"
spctl --assess --type execute --verbose=2 "$app"
rm "$out/notarize.zip"

zip="$out/nks-talk-macos-$name-$number.zip"
/usr/bin/ditto -c -k --keepParent "$app" "$zip"
python3 tool/macos_appcast.py "$zip"
test -s "$out/appcast.xml"
shasum -a 256 "$zip"
echo "== MACOS_RELEASE_READY $zip"
