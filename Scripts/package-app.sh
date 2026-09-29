#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

CONFIGURATION="${1:-debug}"
PRODUCT="photo-engine-mac"
APP_NAME="Photocore"
BUNDLE_ID="com.photocore.app"
ICON_SRC="$ROOT/Sources/photo-engine-mac/Resources/AppIcon.png"
DIST="$ROOT/dist"
APP="$DIST/$APP_NAME.app"

if [[ "$CONFIGURATION" == "release" ]]; then
  swift build -c release --product "$PRODUCT"
  BIN="$ROOT/.build/release/$PRODUCT"
else
  swift build --product "$PRODUCT"
  BIN="$ROOT/.build/debug/$PRODUCT"
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

# Bundle SPM resource bundle next to the executable when present.
for candidate in \
  "$(dirname "$BIN")/PhotoEngine_${PRODUCT}.bundle" \
  "$(dirname "$BIN")/${PRODUCT}_${PRODUCT}.bundle"
do
  if [[ -d "$candidate" ]]; then
    cp -R "$candidate" "$APP/Contents/Resources/"
    break
  fi
done

cp "$BIN" "$APP/Contents/MacOS/$APP_NAME"
chmod +x "$APP/Contents/MacOS/$APP_NAME"

# Optional app icon.
if [[ -f "$ICON_SRC" ]]; then
  TMP="$(mktemp -d)"
  MASTER="$TMP/master.png"
  ICONSET="$TMP/AppIcon.iconset"
  mkdir -p "$ICONSET"
  sips -s format png -z 1024 1024 "$ICON_SRC" --out "$MASTER" >/dev/null
  declare -a PAIRS=(
    "16 icon_16x16.png"
    "32 icon_16x16@2x.png"
    "32 icon_32x32.png"
    "64 icon_32x32@2x.png"
    "128 icon_128x128.png"
    "256 icon_128x128@2x.png"
    "256 icon_256x256.png"
    "512 icon_256x256@2x.png"
    "512 icon_512x512.png"
    "1024 icon_512x512@2x.png"
  )
  for pair in "${PAIRS[@]}"; do
    size="${pair%% *}"
    name="${pair#* }"
    sips -z "$size" "$size" "$MASTER" --out "$ICONSET/$name" >/dev/null
  done
  if iconutil -c icns -o "$APP/Contents/Resources/AppIcon.icns" "$ICONSET"; then
    :
  else
    echo "warning: could not build AppIcon.icns; continuing without it" >&2
  fi
  rm -rf "$TMP"
fi

cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleExecutable</key>
  <string>$APP_NAME</string>
  <key>CFBundleIdentifier</key>
  <string>$BUNDLE_ID</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>$APP_NAME</string>
  <key>CFBundleDisplayName</key>
  <string>$APP_NAME</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>0.5.0</string>
  <key>CFBundleVersion</key>
  <string>0.5.0</string>
  <key>LSMinimumSystemVersion</key>
  <string>15.0</string>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
  <key>NSSupportsAutomaticGraphicsSwitching</key>
  <true/>
</dict>
</plist>
EOF

# Ad-hoc sign so Gatekeeper is less noisy for local runs.
codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || true

echo "Built $APP"
open "$APP"
