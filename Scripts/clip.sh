#!/bin/zsh
# Builds Bound (with its App Clip), installs the App Clip on the booted
# simulator and opens it on an invite link, the way tapping the link would.
#   Scripts/clip.sh http://localhost:8799/j/<code>
# Start a local server first with Scripts/dev-server.sh.
set -euo pipefail
cd "$(dirname "$0")/.."
INVITE="${1:?Pass an invite link, for example http://localhost:8799/j/<code>}"
DEVICE="${DEVICE:-iPhone 18 Pro}"
xcodebuild -project Apps/PhotocoreiOS/PhotocoreiOS.xcodeproj -scheme PhotocoreiOS \
  -destination "platform=iOS Simulator,name=$DEVICE" -derivedDataPath .build/app-dd build 2>&1 \
  | grep -E "error:|BUILD"
xcrun simctl install booted .build/app-dd/Build/Products/Debug-iphonesimulator/BoundClip.app
xcrun simctl launch --terminate-running-process booted com.photocore.trip.Clip -BoundInviteURL "$INVITE"
