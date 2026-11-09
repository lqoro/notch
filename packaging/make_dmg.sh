#!/bin/bash
# Packs NotchDeck.app (built with ./build.sh --release) into a drag-to-Applications disk image,
# signs it, notarizes it, staples the ticket and checks the result.
#
#   NOTARY_PROFILE=<notarytool keychain profile> packaging/make_dmg.sh
#
# Set NOTARIZE=0 to skip notarization (local tests only).
set -euo pipefail
cd "$(dirname "$0")/.."

APP="NotchDeck.app"
[[ -d "$APP" ]] || { echo "Build first: ./build.sh --release" >&2; exit 1; }
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
SIGN_ID="${SIGN_ID:-$(security find-identity -v -p codesigning | grep -m1 '"Developer ID Application:' | awk '{print $2}')}"
[[ -n "$SIGN_ID" ]] || { echo "No Developer ID Application identity (set SIGN_ID)." >&2; exit 1; }
NOTARIZE="${NOTARIZE:-1}"

mkdir -p dist
DMG="dist/NotchDeck-$VERSION.dmg"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
ditto "$APP" "$STAGE/NotchDeck.app"
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG"
hdiutil create -volname "NotchDeck $VERSION" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG" >/dev/null
codesign --force --sign "$SIGN_ID" --timestamp "$DMG"

if [[ "$NOTARIZE" == 1 ]]; then
    : "${NOTARY_PROFILE:?set NOTARY_PROFILE to your notarytool keychain profile}"
    xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$DMG"
    xcrun stapler validate "$DMG"
    spctl --assess --type open --context context:primary-signature -v "$DMG"
fi
codesign --verify --strict -v "$DMG"
shasum -a 256 "$DMG"
