#!/bin/bash
# Builds a universal (Apple silicon + Intel) Release copy of the app and zips it,
# so one build can be copied to any Mac running macOS 14 or later.
set -euo pipefail
cd "$(dirname "$0")/.."

if command -v xcodegen >/dev/null; then
  xcodegen generate --quiet
fi

rm -rf build/Release dist
# Sign with your Apple Development certificate but no provisioning profile: none of
# the entitlements need one, and a development profile would only run on Macs
# registered to your team.
xcodebuild -project WashTowerWidget.xcodeproj -scheme WashTowerWidget \
  -configuration Release -destination 'generic/platform=macOS' \
  -derivedDataPath build/DerivedData \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="Apple Development" PROVISIONING_PROFILE_SPECIFIER= \
  ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO \
  CONFIGURATION_BUILD_DIR="$PWD/build/Release" \
  build | grep -E "error:|warning:|BUILD (SUCCEEDED|FAILED)" || true

APP="build/Release/WashTower Widget.app"
[ -d "$APP" ] || { echo "Build failed; run without the grep filter to see why."; exit 1; }

codesign --verify --deep --strict "$APP"
echo "Architectures: $(lipo -archs "$APP/Contents/MacOS/WashTower Widget")"
if [ -e "$APP/Contents/embedded.provisionprofile" ]; then
  echo "Note: a provisioning profile is embedded; the build may only run on Macs registered to your team."
fi

mkdir -p dist
ditto -c -k --keepParent "$APP" dist/WashTower-Widget.zip
echo "Wrote dist/WashTower-Widget.zip"
