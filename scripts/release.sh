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

echo "==> Creating DMG..."
DMG_PATH="$BUILD_DIR/$DMG_NAME"
hdiutil create -volname "$APP_NAME" \
  -srcfolder "$APP_PATH" \
  -ov -format UDZO \
  "$DMG_PATH"

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

echo ""
echo "=== Release complete ==="
echo "DMG: $DMG_PATH"
echo ""
echo "Upload to GitHub Releases:"
echo "  gh release create v$VERSION '$DMG_PATH' --title 'v$VERSION' --notes 'Release notes here'"
