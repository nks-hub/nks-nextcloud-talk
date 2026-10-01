#!/bin/bash
set -euo pipefail

app=${1:?Application bundle is required}
identity=${2:?Signing identity is required}
sparkle="$app/Contents/Frameworks/Sparkle.framework/Versions/B"

sign() {
  /usr/bin/codesign --force --options runtime --timestamp --sign "$identity" "$@"
}

# Code Sign on Copy does not re-sign Sparkle's nested installer services.
sign "$sparkle/XPCServices/Installer.xpc"
sign --preserve-metadata=entitlements "$sparkle/XPCServices/Downloader.xpc"
sign "$sparkle/Autoupdate"
sign "$sparkle/Updater.app"
sign "$sparkle"
