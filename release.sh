#!/bin/bash
# Builds a universal (Apple Silicon + Intel) CallRecorder.app, signs it with your Developer ID, notarizes and staples it,
# and zips it to build/CallRecorder.zip. Needs a "Developer ID Application" certificate and notarytool credentials
# saved once with:  xcrun notarytool store-credentials CallRecorder   (or set NOTARY_PROFILE to another profile name).
set -euo pipefail
cd "$(dirname "$0")"
IDENTITY="${SIGN_IDENTITY:-Developer ID Application}"
swift build -c release --arch arm64 --arch x86_64
APP=build/CallRecorder.app
rm -rf "$APP" build/CallRecorder.zip
mkdir -p "$APP/Contents/MacOS"
cp "$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/CallRecorder" "$APP/Contents/MacOS/"
cp Resources/Info.plist "$APP/Contents/"
codesign --force --options runtime --timestamp --entitlements Resources/CallRecorder.entitlements --sign "$IDENTITY" "$APP"
ditto -c -k --keepParent "$APP" build/CallRecorder.zip
if [ "${SKIP_NOTARIZE:-}" = "1" ]; then echo "Signed, not notarized: build/CallRecorder.zip"; exit 0; fi
xcrun notarytool submit build/CallRecorder.zip --keychain-profile "${NOTARY_PROFILE:-CallRecorder}" --wait
xcrun stapler staple "$APP"
rm build/CallRecorder.zip
ditto -c -k --keepParent "$APP" build/CallRecorder.zip
spctl --assess --type execute --verbose "$APP"
echo "Notarized: build/CallRecorder.zip"
