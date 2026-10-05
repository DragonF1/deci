#!/bin/bash
set -e

# AdvancedAudioControl DMG Build Script
# Requires: Xcode, Node.js 18+, GraphicsMagick, ImageMagick
# Install dependencies: brew install graphicsmagick imagemagick

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
BUILD_DIR="$PROJECT_DIR/build"

echo "==> Cleaning build directory..."
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

echo "==> Building release archive..."
xcodebuild -project "$PROJECT_DIR/AdvancedAudioControl.xcodeproj" \
    -scheme AdvancedAudioControl \
    -configuration Release \
    -archivePath "$BUILD_DIR/AdvancedAudioControl.xcarchive" \
    archive

echo "==> Exporting notarized app..."
xcodebuild -exportArchive \
    -archivePath "$BUILD_DIR/AdvancedAudioControl.xcarchive" \
    -exportPath "$BUILD_DIR" \
    -exportOptionsPlist "$PROJECT_DIR/ExportOptions.plist"

echo "==> Creating DMG..."
# create-dmg auto-generates professional layout with:
# - App icon composited onto disk icon
# - "Drag to Applications" layout
# - Code signing
npx create-dmg "$BUILD_DIR/AdvancedAudioControl.app" "$BUILD_DIR" --overwrite

echo "==> Done!"
echo "DMG created at: $BUILD_DIR/"
ls -la "$BUILD_DIR"/*.dmg
