#!/bin/bash
set -euo pipefail

# Release script for ClaudeBattery
# Usage: ./scripts/release.sh
#
# Prerequisites:
#   1. "Developer ID Application" certificate installed in Keychain
#   2. Store notarization credentials once:
#      xcrun notarytool store-credentials "ClaudeBattery" \
#        --apple-id "your@email.com" \
#        --team-id "PJHS9XQS6H" \
#        --password "app-specific-password"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$SCRIPT_DIR/../ClaudeBattery"
# Build outside iCloud/FileProvider to avoid com.apple.provenance extended attributes
BUILD_DIR="/tmp/ClaudeBattery-build"
APP_NAME="ClaudeBattery"
SCHEME="ClaudeBattery"
KEYCHAIN_PROFILE="ClaudeBattery"
SIGNING_IDENTITY="Developer ID Application: [REDACTED]"

# Read version from project
VERSION=$(grep -m1 'MARKETING_VERSION' "$PROJECT_DIR/$APP_NAME.xcodeproj/project.pbxproj" | sed 's/.*= //;s/;//')
DMG_NAME="claude-battery_v${VERSION}.dmg"

echo "==> Cleaning extended attributes and build artifacts..."
xattr -rc "$PROJECT_DIR/"
find "$PROJECT_DIR" -name ".DS_Store" -delete
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

echo "==> Building $APP_NAME v$VERSION (Release)..."

xcodebuild -project "$PROJECT_DIR/$APP_NAME.xcodeproj" \
  -scheme "$SCHEME" \
  -configuration Release \
  -derivedDataPath "$BUILD_DIR/derived" \
  -archivePath "$BUILD_DIR/$APP_NAME.xcarchive" \
  archive

echo "==> Exporting archive..."
cat > "$BUILD_DIR/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>developer-id</string>
    <key>teamID</key>
    <string>PJHS9XQS6H</string>
    <key>signingStyle</key>
    <string>manual</string>
    <key>signingCertificate</key>
    <string>Developer ID Application</string>
</dict>
</plist>
PLIST

xcodebuild -exportArchive \
  -archivePath "$BUILD_DIR/$APP_NAME.xcarchive" \
  -exportPath "$BUILD_DIR/export" \
  -exportOptionsPlist "$BUILD_DIR/ExportOptions.plist"

APP_PATH="$BUILD_DIR/export/$APP_NAME.app"

echo "==> Verifying code signature..."
codesign --verify --deep --strict --verbose=2 "$APP_PATH"
echo "    Signature OK"

echo "==> Creating DMG with Applications shortcut..."
DMG_PATH="$BUILD_DIR/$DMG_NAME"
DMG_STAGING="$BUILD_DIR/dmg-staging"
rm -rf "$DMG_STAGING"
mkdir -p "$DMG_STAGING"
cp -R "$APP_PATH" "$DMG_STAGING/"
ln -s /Applications "$DMG_STAGING/Applications"

# Create a temporary read-write DMG
DMG_TEMP="$BUILD_DIR/temp.dmg"
hdiutil create -volname "$APP_NAME" \
  -srcfolder "$DMG_STAGING" \
  -ov -format UDRW \
  -size 200m \
  "$DMG_TEMP"

# Mount, set Finder layout, unmount
MOUNT_DIR=$(hdiutil attach -readwrite -noverify "$DMG_TEMP" | grep "/Volumes/" | sed 's/.*\/Volumes/\/Volumes/')
sleep 1

# Set Finder window appearance via AppleScript
osascript <<APPLESCRIPT
tell application "Finder"
    tell disk "$APP_NAME"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set bounds of container window to {100, 100, 640, 400}
        set theViewOptions to icon view options of container window
        set arrangement of theViewOptions to not arranged
        set icon size of theViewOptions to 128
        set position of item "$APP_NAME.app" of container window to {140, 150}
        set position of item "Applications" of container window to {400, 150}
        close
        open
        update without registering applications
        delay 1
        close
    end tell
end tell
APPLESCRIPT

sync
hdiutil detach "$MOUNT_DIR"

# Convert to compressed read-only DMG
hdiutil convert "$DMG_TEMP" -format UDZO -o "$DMG_PATH"
rm -f "$DMG_TEMP"
rm -rf "$DMG_STAGING"

echo "==> Signing DMG..."
codesign --sign "$SIGNING_IDENTITY" "$DMG_PATH"

echo "==> Notarizing DMG (this may take a few minutes)..."
xcrun notarytool submit "$DMG_PATH" \
  --keychain-profile "$KEYCHAIN_PROFILE" \
  --wait

echo "==> Stapling notarization ticket..."
xcrun stapler staple "$DMG_PATH"

echo "==> Verifying notarization..."
spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG_PATH"

echo "==> Copying DMG to downloads folder..."
DOWNLOADS_DIR="$SCRIPT_DIR/../downloads"
mkdir -p "$DOWNLOADS_DIR"
cp "$DMG_PATH" "$DOWNLOADS_DIR/$DMG_NAME"

echo ""
echo "=== Release complete ==="
echo "DMG: $DMG_PATH"
echo "Downloads: $DOWNLOADS_DIR/$DMG_NAME"
echo ""
echo "Upload to GitHub Releases:"
echo "  gh release create v$VERSION '$DMG_PATH' --title 'v$VERSION' --notes 'Release notes here'"
