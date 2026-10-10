#!/bin/bash
# Builds PhotoBooth in release mode and assembles + signs dist/PhotoBooth.app.
#
#   scripts/bundle.sh                     # ad-hoc signature
#   SIGN_IDENTITY="PhotoBooth Dev" scripts/bundle.sh   # stable identity from your keychain
#
# Signing note: an ad-hoc signature ("-s -") changes on every build, so macOS treats each
# rebuild as a new app and TCC grants (Input Monitoring for the HID button, Removable
# Volumes / camera access, ...) may have to be granted again after rebuilding. Creating a
# stable self-signed code-signing certificate (Keychain Access → Certificate Assistant →
# Create a Certificate…, type "Code Signing") and passing its name in SIGN_IDENTITY keeps
# the designated requirement stable, so grants survive rebuilds.
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
BUNDLE_ID="com.somefamilies.photobooth"
APP="$ROOT/dist/PhotoBooth.app"
SCRATCH="$ROOT/.build-release"

echo "==> Building (release)"
swift build -c release --scratch-path "$SCRATCH" --product PhotoBooth
BIN="$(swift build -c release --scratch-path "$SCRATCH" --show-bin-path)/PhotoBooth"

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/PhotoBooth"

VERSION="${VERSION:-0.2.0}"
BUILD="${BUILD:-$(date +%Y%m%d%H%M)}"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>${BUNDLE_ID}</string>
    <key>CFBundleName</key>
    <string>PhotoBooth</string>
    <key>CFBundleDisplayName</key>
    <string>PhotoBooth</string>
    <key>CFBundleExecutable</key>
    <string>PhotoBooth</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>${VERSION}</string>
    <key>CFBundleVersion</key>
    <string>${BUILD}</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
</dict>
</plist>
PLIST

echo "==> Signing"
if [[ -n "${SIGN_IDENTITY:-}" ]]; then
    codesign --force --options runtime --timestamp=none -s "$SIGN_IDENTITY" --identifier "$BUNDLE_ID" "$APP"
else
    echo "    (ad-hoc; set SIGN_IDENTITY for a stable signature — see comment at top)"
    codesign --force -s - --identifier "$BUNDLE_ID" "$APP"
fi
codesign --verify --verbose=2 "$APP"

echo "==> Done: $APP"
echo "    Run: open \"$APP\" --args --fake-camera --windowed"
