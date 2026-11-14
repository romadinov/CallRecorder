#!/bin/bash
# Builds CallRecorder.app into build/. Signs it ad hoc ("-") unless SIGN_IDENTITY names a certificate, e.g.
#   SIGN_IDENTITY="Apple Development: you@example.com" ./build.sh
# With an ad hoc signature macOS asks for Microphone and System Audio Recording again after each rebuild.
# ./release.sh builds a universal, Developer ID-signed, notarized zip for GitHub Releases.
set -euo pipefail
cd "$(dirname "$0")"
swift build -c release
APP=build/CallRecorder.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$(swift build -c release --show-bin-path)/CallRecorder" "$APP/Contents/MacOS/"
cp Resources/Info.plist "$APP/Contents/"
IDENTITY="${SIGN_IDENTITY:--}"
STAMP=(); [ "$IDENTITY" != "-" ] && STAMP=(--timestamp)  # a secure timestamp is needed for notarization
codesign --force --options runtime "${STAMP[@]+"${STAMP[@]}"}" --entitlements Resources/CallRecorder.entitlements --sign "$IDENTITY" "$APP"
echo "Built $APP. Move it to /Applications and open it."
