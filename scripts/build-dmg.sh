#!/bin/bash
set -euo pipefail

# Builds a distributable Deci DMG (universal: Apple silicon + Intel) with the
# DeciHost native messaging helper inside the app.
#
# Signing is picked automatically:
#   - A "Developer ID Application" identity in the keychain: the app is signed with
#     it (hardened runtime, secure timestamp). If the notarytool keychain profile
#     named by NOTARY_PROFILE (default "deci-notary") exists, the DMG is also
#     notarized and stapled (app and DMG), so it opens on any Mac with no warning.
#     One-time setup after joining the Apple Developer Program:
#       xcrun notarytool store-credentials deci-notary --apple-id <apple id> --team-id <team id>
#   - SIGN_IDENTITY naming any other code signing identity (a self-signed certificate
#     made in Keychain Access): the app is signed with it but not notarized, so other
#     Macs block the first launch until the user clicks Open Anyway in System Settings >
#     Privacy & Security (the DMG carries a short note explaining it). Use the SAME
#     certificate for every release: macOS ties the audio recording permission to it,
#     so users keep the permission across updates. Never use a certificate whose name
#     or subject holds an email address, since the certificate ships inside the app.
#   - Neither: the app is ad-hoc signed. Same first-launch note, but macOS asks for the
#     audio recording permission again after every update.
#
# Environment overrides: SIGN_IDENTITY (identity name or SHA-1 hash), NOTARY_PROFILE,
# REQUIRE_NOTARIZATION=1 (fail instead of shipping a signed but un-notarized DMG),
# COPY_TO (folder that gets a copy of the DMG, default ~/Desktop, empty to skip),
# BUILD_ROOT (folder for the build and the DMG, default build/ in the repo).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
BUILD_ROOT="${BUILD_ROOT:-$PROJECT_DIR/build}"
OUT_DIR="$BUILD_ROOT/release"
DERIVED_DIR="$BUILD_ROOT/release-derived"
NOTARY_PROFILE="${NOTARY_PROFILE:-deci-notary}"
COPY_TO="${COPY_TO-$HOME/Desktop}"

# Listed once, without -v so untrusted self-signed certificates show up too. Matching
# against a here-string keeps grep -q from breaking a pipeline under pipefail.
IDENTITIES="$(security find-identity -p codesigning)"
if [ -n "${SIGN_IDENTITY:-}" ]; then
    MATCH="$(grep -F -e "$SIGN_IDENTITY" <<< "$IDENTITIES" || true)"
    if [ -z "$MATCH" ]; then
        echo "!! No code signing identity matches SIGN_IDENTITY \"$SIGN_IDENTITY\"." >&2
        exit 1
    fi
    # Apple's personal certificates carry the account email and team ID into the signature.
    if grep -qE '"(Apple Development|Apple Distribution|Mac Developer|Developer ID Installer): |@' <<< "$MATCH"; then
        echo "!! SIGN_IDENTITY \"$SIGN_IDENTITY\" is a personal or installer certificate; use a" >&2
        echo "   Developer ID Application or a self-signed certificate without an email." >&2
        exit 1
    fi
fi

# Auto-detected identities are picked by certificate hash, so the same certificate in
# two keychains is not ambiguous.
IDENTITY="${SIGN_IDENTITY:-$(security find-identity -v -p codesigning \
    | awk '/"Developer ID Application: / && !h {h=$2} END {print h}')}"
NOTARIZE=0
if [ -z "$IDENTITY" ]; then
    MODE="adhoc"
    IDENTITY="-"
    TIMESTAMP="--timestamp=none"
elif grep -F -e "$IDENTITY" <<< "$IDENTITIES" | grep '"Developer ID Application: ' >/dev/null; then
    MODE="developer-id"
    TIMESTAMP="--timestamp"
    if xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
        NOTARIZE=1
    elif [ "${REQUIRE_NOTARIZATION:-0}" = "1" ]; then
        echo "!! notarytool profile \"$NOTARY_PROFILE\" is missing or unreachable." >&2
        exit 1
    fi
else
    MODE="self-signed"
    TIMESTAMP="--timestamp=none"
fi

notarize() {
    local result id status
    result="$(xcrun notarytool submit "$1" --keychain-profile "$NOTARY_PROFILE" --wait --output-format json)"
    id="$(plutil -extract id raw -o - - <<< "$result")"
    status="$(plutil -extract status raw -o - - <<< "$result")"
    if [ "$status" != "Accepted" ]; then
        echo "!! Notarization of $1 ended as $status:" >&2
        xcrun notarytool log "$id" --keychain-profile "$NOTARY_PROFILE" >&2 || true
        exit 1
    fi
}

# Apple's ticket can take a few seconds to show up after "Accepted".
staple() {
    local attempt
    for attempt in 1 2 3 4 5; do
        xcrun stapler staple "$1" && return 0
        sleep 10
    done
    echo "!! Could not staple $1" >&2
    exit 1
}

MIN_MACOS="$(sed -n 's/.*MACOSX_DEPLOYMENT_TARGET = \([0-9.]*\);.*/\1/p' \
    "$PROJECT_DIR/Deci.xcodeproj/project.pbxproj" | head -1)"

rm -rf "$OUT_DIR"
mkdir -p "$OUT_DIR"

echo "==> Building universal Release app (signing: $MODE)..."
xcodebuild -project "$PROJECT_DIR/Deci.xcodeproj" \
    -scheme Deci \
    -configuration Release \
    -clonedSourcePackagesDirPath "$PROJECT_DIR/SourcePackages" \
    -derivedDataPath "$DERIVED_DIR" \
    -destination 'generic/platform=macOS' \
    ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO \
    CODE_SIGNING_ALLOWED=NO \
    -quiet build

APP="$OUT_DIR/Deci.app"
ditto "$DERIVED_DIR/Build/Products/Release/Deci.app" "$APP"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist")"

echo "==> Building DeciHost (macOS $MIN_MACOS+, universal)..."
HOST_TMP="$(mktemp -d)"
trap 'rm -rf "$HOST_TMP"' EXIT
for arch in arm64 x86_64; do
    swiftc -O -target "$arch-apple-macos$MIN_MACOS" \
        "$PROJECT_DIR/DeciHost/main.swift" -o "$HOST_TMP/DeciHost-$arch"
done
lipo -create "$HOST_TMP/DeciHost-arm64" "$HOST_TMP/DeciHost-x86_64" \
    -output "$APP/Contents/MacOS/DeciHost"
chmod +x "$APP/Contents/MacOS/DeciHost"

echo "==> Signing inside out..."
sign() { codesign --force $TIMESTAMP --options runtime --sign "$IDENTITY" "$@"; }

# Sparkle's nested helpers first, in the order Sparkle documents, then the framework.
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework"
if [ -d "$SPARKLE" ]; then
    for xpc in "$SPARKLE"/Versions/B/XPCServices/*.xpc; do
        [ -e "$xpc" ] && sign --preserve-metadata=entitlements "$xpc"
    done
    [ -e "$SPARKLE/Versions/B/Autoupdate" ] && sign "$SPARKLE/Versions/B/Autoupdate"
    [ -e "$SPARKLE/Versions/B/Updater.app" ] && sign "$SPARKLE/Versions/B/Updater.app"
    sign "$SPARKLE"
fi
sign "$APP/Contents/MacOS/DeciHost"
sign --entitlements "$PROJECT_DIR/Deci/Deci.entitlements" "$APP"
codesign --verify --deep --strict "$APP"

# The app gets its own ticket so a copy dragged out of the DMG passes Gatekeeper offline.
if [ "$NOTARIZE" = "1" ]; then
    echo "==> Notarizing the app (this can take a few minutes)..."
    ditto -c -k --keepParent "$APP" "$HOST_TMP/Deci.zip"
    notarize "$HOST_TMP/Deci.zip"
    staple "$APP"
fi

echo "==> Creating DMG..."
STAGE="$OUT_DIR/dmg"
mkdir -p "$STAGE"
ditto "$APP" "$STAGE/Deci.app"
ln -s /Applications "$STAGE/Applications"
if [ "$NOTARIZE" != "1" ]; then
    cat > "$STAGE/If Deci won't open.txt" <<'EOF'
Deci is not notarized by Apple yet, so macOS blocks the first launch once.

1. Drag Deci into Applications.
2. Open Deci. macOS says it cannot verify the app. Click Done.
3. Open System Settings > Privacy & Security, scroll down to Security,
   click "Open Anyway" next to Deci, and confirm with your password.

Deci opens normally from then on.

Terminal alternative (after step 1):
  xattr -dr com.apple.quarantine /Applications/Deci.app

Chrome tab control: open Deci's Settings > General > Chrome and click
Install Extension, then follow the three steps it shows.
EOF
fi
DMG="$OUT_DIR/Deci-$VERSION.dmg"
hdiutil create -quiet -volname "Deci" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG"
rm -rf "$STAGE"

if [ "$MODE" = "developer-id" ]; then
    codesign --force --timestamp --sign "$IDENTITY" "$DMG"
    if [ "$NOTARIZE" = "1" ]; then
        echo "==> Notarizing the DMG..."
        notarize "$DMG"
        staple "$DMG"
        spctl --assess --type open --context context:primary-signature -v "$DMG"
    else
        echo "!! No notarytool profile \"$NOTARY_PROFILE\": the DMG is signed but not notarized."
    fi
fi

if [ -n "$COPY_TO" ]; then
    ditto "$DMG" "$COPY_TO/$(basename "$DMG")"
    echo "==> Copied to $COPY_TO/$(basename "$DMG")"
fi

echo "==> Done ($MODE): $DMG"
