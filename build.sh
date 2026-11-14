#!/bin/bash
# Builds CallRecorder.app into build/. Signs it ad hoc ("-") unless SIGN_IDENTITY names a certificate, e.g.
#   SIGN_IDENTITY="Apple Development: you@example.com" ./build.sh
# With an ad hoc signature macOS asks for Microphone and System Audio Recording again after each rebuild.
set -euo pipefail
cd "$(dirname "$0")"
swift build -c release
APP=build/CallRecorder.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$(swift build -c release --show-bin-path)/CallRecorder" "$APP/Contents/MacOS/"
cp Resources/Info.plist "$APP/Contents/"
codesign --force --options runtime --entitlements Resources/CallRecorder.entitlements --sign "${SIGN_IDENTITY:--}" "$APP"
echo "Built $APP. Move it to /Applications and open it."
