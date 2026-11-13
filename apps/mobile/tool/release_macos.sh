#!/bin/bash
# Builds the macOS release ZIP for the checked-out tag: Developer ID signature,
# notarization, stapling and the signed Sparkle appcast. Run from apps/mobile on
# the build Mac as the signed-in user, with the login keychain unlocked.
#
#   tool/release_macos.sh <telemetry.env> <build.env> <asc-key.p8> <key-id> <issuer>
#
# Writes build/macos-release/nks-talk-macos-<version>-<build>.zip and appcast.xml.
set -euo pipefail

telemetry=${1:?telemetry.env}
build_env=${2:?build.env with PUSH_GATEWAY_ORIGIN}
key=${3:?App Store Connect API key}
key_id=${4:?key id}
issuer=${5:?issuer id}
# shellcheck disable=SC1090
source "$build_env"
: "${PUSH_GATEWAY_ORIGIN:?build.env must set PUSH_GATEWAY_ORIGIN}"

identity=$(security find-identity -v -p codesigning | grep -m1 -o '"Developer ID Application: [^"]*"' | tr -d '"')
test -n "$identity" || { echo "no Developer ID Application identity in the keychain" >&2; exit 1; }
echo "== identity: $identity"

version=$(grep '^version:' pubspec.yaml | cut -d' ' -f2)
name=${version%+*}
number=${version#*+}
out=build/macos-release
rm -rf "$out"
mkdir -p "$out"

flutter build macos --release --dart-define-from-file="$telemetry" \
  --dart-define="PUSH_GATEWAY_ORIGIN=$PUSH_GATEWAY_ORIGIN"
app=build/macos/Build/Products/Release/nextcloudtalk.app
test -d "$app"

sign() { /usr/bin/codesign --force --options runtime --timestamp --sign "$identity" "$@"; }

# Inside out: Sparkle's helpers, every other embedded framework and library,
# app extensions with their own entitlements, then the application.
bash tool/sign_sparkle.sh "$app" "$identity"
find "$app/Contents/Frameworks" -maxdepth 1 \( -name '*.framework' -o -name '*.dylib' \) \
  ! -name 'Sparkle.framework' -print0 | while IFS= read -r -d '' item; do sign "$item"; done
if [ -d "$app/Contents/PlugIns" ]; then
  find "$app/Contents/PlugIns" -maxdepth 1 -name '*.appex' -print0 |
    while IFS= read -r -d '' ext; do sign --preserve-metadata=entitlements "$ext"; done
fi
sign --entitlements macos/Runner/Release.entitlements "$app"
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
