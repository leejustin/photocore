#!/bin/zsh
# Builds the Photocore iPhone app, installs it on the booted simulator, grants
# Photos access and launches it. Extra arguments pass through as launch options,
# for example: Scripts/ios-app.sh -PhotocoreAutoOpen YES -PhotocoreAutoSwipe YES
# Seed the simulator first with: xcrun simctl addmedia booted /path/*.JPG
set -euo pipefail
cd "$(dirname "$0")/.."
DEVICE="${DEVICE:-iPhone 18 Pro}"
xcodebuild -project Apps/PhotocoreiOS/PhotocoreiOS.xcodeproj -scheme PhotocoreiOS \
  -destination "platform=iOS Simulator,name=$DEVICE" -derivedDataPath .build/app-dd build 2>&1 \
  | grep -E "error:|BUILD"
xcrun simctl install booted .build/app-dd/Build/Products/Debug-iphonesimulator/Photocore.app
xcrun simctl privacy booted grant photos com.photocore.trip
xcrun simctl launch --terminate-running-process booted com.photocore.trip "$@"
