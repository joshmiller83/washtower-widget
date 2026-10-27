#!/bin/bash
# Builds the iPhone app (Debug) and installs it on your phone over USB or home Wi-Fi.
# Put your phone's ids in Config/device.env (git-ignored):
#   DEVICE_ID=<from `xcrun xctrace list devices`>
#   DEVICECTL_ID=<from `xcrun devicectl list devices`>
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

[[ -f Config/device.env ]] || { echo "Missing Config/device.env (see the comment at the top of this script)"; exit 1; }
# shellcheck source=/dev/null
source Config/device.env
if command -v xcodegen >/dev/null; then xcodegen generate --quiet; fi

xcodebuild build -quiet -project WashTowerWidget.xcodeproj -scheme WashTower -configuration Debug \
  -destination "id=$DEVICE_ID" -derivedDataPath build/DerivedData -allowProvisioningUpdates
xcrun devicectl device install app --device "$DEVICECTL_ID" build/DerivedData/Build/Products/Debug-iphoneos/WashTower.app
echo "Installed. Open WashTower on the phone, then pair it with deploy/pair.sh."
