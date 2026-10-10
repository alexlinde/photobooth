#!/bin/bash
# Builds PhotoBooth in release mode and assembles + signs dist/PhotoBooth.app.
#
#   scripts/bundle.sh                                  # Developer ID if present, else ad-hoc
#   SIGN_IDENTITY="Developer ID Application: …" scripts/bundle.sh
#   SIGN_IDENTITY=- scripts/bundle.sh                  # force ad-hoc
#   NOTARY_PROFILE=photobooth scripts/bundle.sh        # also notarize + staple (see below)
#
# Why a stable identity matters: macOS ties privacy grants (Input Monitoring for the HID
# button, Removable Volumes for the camera) and Keychain access (the Google refresh token) to
# the app's signature. An ad-hoc signature changes on every build, so each rebuild looks like
# a new app and those prompts come back — a Keychain prompt would block an unattended booth.
# A Developer ID (or a self-signed "Code Signing" certificate) keeps them across rebuilds.
#
# Notarization is only needed to run the app on another Mac (e.g. after downloading it). One-time
# setup: xcrun notarytool store-credentials photobooth --apple-id <id> --team-id <team>
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
if [[ -z "${SIGN_IDENTITY:-}" ]]; then
    SIGN_IDENTITY="$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application: .*\)"/\1/p' | head -1)"
fi
if [[ -n "${SIGN_IDENTITY:-}" && "$SIGN_IDENTITY" != "-" ]]; then
    echo "    $SIGN_IDENTITY"
    # Hardened runtime + secure timestamp: required for notarization, harmless otherwise.
    codesign --force --options runtime --timestamp -s "$SIGN_IDENTITY" --identifier "$BUNDLE_ID" "$APP"
else
    echo "    ad-hoc (no Developer ID found; set SIGN_IDENTITY for a stable signature — see top)"
    codesign --force -s - --identifier "$BUNDLE_ID" "$APP"
fi
codesign --verify --verbose=2 "$APP"

if [[ -n "${NOTARY_PROFILE:-}" ]]; then
    echo "==> Notarizing (profile $NOTARY_PROFILE)"
    ZIP="$ROOT/dist/PhotoBooth.zip"
    ditto -c -k --keepParent "$APP" "$ZIP"
    xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$APP"
    rm -f "$ZIP"
fi

echo "==> Done: $APP"
echo "    First run (grant permissions): open \"$APP\" --args --windowed"
