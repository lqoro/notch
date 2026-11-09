#!/bin/bash
# Builds NotchDeck.app.
#
#   ./build.sh              dev build, signed with your Apple Development identity (auto-detected)
#   ./build.sh --release    Developer ID + hardened runtime + secure timestamp, ready to notarize
#
# Environment overrides:
#   SIGN_ID          signing identity (name or hash); SIGN_ID=- for ad hoc
#   VERSION, BUILD   CFBundleShortVersionString / CFBundleVersion (default 1.0.0 / 1)
#   SU_PUBLIC_ED_KEY Sparkle public update key (default: packaging/sparkle_public_key.txt)
#   SU_FEED_URL      update feed (default https://notch.lqoro.com/appcast.xml)
set -euo pipefail
cd "$(dirname "$0")"

RELEASE=0
[[ "${1:-}" == "--release" ]] && RELEASE=1

VERSION="${VERSION:-1.0.0}"
BUILD="${BUILD:-1}"
SU_FEED_URL="${SU_FEED_URL:-https://notch.lqoro.com/appcast.xml}"
if [[ -z "${SU_PUBLIC_ED_KEY:-}" && -f packaging/sparkle_public_key.txt ]]; then
    SU_PUBLIC_ED_KEY="$(tr -d '[:space:]' < packaging/sparkle_public_key.txt)"
fi
SU_PUBLIC_ED_KEY="${SU_PUBLIC_ED_KEY:-}"

# Pick a signing identity. A stable identity matters even for dev builds: ad hoc signatures change
# every build and silently invalidate Accessibility / Full Disk Access / Automation grants.
find_identity() { security find-identity -v -p codesigning | grep -m1 "\"$1" | awk '{print $2}' || true; }
if [[ -z "${SIGN_ID:-}" ]]; then
    if (( RELEASE )); then SIGN_ID="$(find_identity 'Developer ID Application:')"
    else SIGN_ID="$(find_identity 'Apple Development:')"; fi
fi
if [[ -z "${SIGN_ID:-}" ]]; then
    if (( RELEASE )); then echo "No Developer ID Application identity found (set SIGN_ID)." >&2; exit 1; fi
    echo "No Apple Development identity found; signing ad hoc." >&2
    SIGN_ID="-"
fi
if (( RELEASE )) && [[ -z "$SU_PUBLIC_ED_KEY" ]]; then
    echo "Release builds need the Sparkle public key (packaging/sparkle_public_key.txt or SU_PUBLIC_ED_KEY)." >&2
    exit 1
fi

swift build -c release
BIN_DIR="$(swift build -c release --show-bin-path)"

APP="NotchDeck.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$BIN_DIR/NotchDeck" "$APP/Contents/MacOS/NotchDeck"

# Sparkle. NotchDeck is not sandboxed, so Sparkle's XPC services (only needed by sandboxed apps)
# are left out: fewer programs to sign and trust.
ditto "$BIN_DIR/Sparkle.framework" "$APP/Contents/Frameworks/Sparkle.framework"
rm -rf "$APP/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices" \
       "$APP/Contents/Frameworks/Sparkle.framework/XPCServices"

# System Now Playing helper: a tiny dylib loaded by Apple's /usr/bin/perl, which is allowed to read
# the private MediaRemote framework (third-party apps are not, since macOS 15.4).
mkdir -p "$APP/Contents/Resources/np"
clang -dynamiclib -fobjc-arc -mmacosx-version-min=14.0 -framework Foundation Helper/np.m \
    -o "$APP/Contents/Resources/np/libnp.dylib"
cp Helper/run.pl "$APP/Contents/Resources/np/run.pl"
cp LICENSE THIRD_PARTY_NOTICES.md "$APP/Contents/Resources/" 2>/dev/null || true

SPARKLE_KEYS=""
if [[ -n "$SU_PUBLIC_ED_KEY" ]]; then
    SPARKLE_KEYS="    <key>SUFeedURL</key><string>${SU_FEED_URL}</string>
    <key>SUPublicEDKey</key><string>${SU_PUBLIC_ED_KEY}</string>
    <key>SUEnableAutomaticChecks</key><true/>
    <key>SUScheduledCheckInterval</key><integer>86400</integer>
    <key>SUAllowsAutomaticUpdates</key><false/>
    <key>SUAutomaticallyUpdate</key><false/>
    <key>SUEnableSystemProfiling</key><false/>"
fi
# Local update tests only: allow a plain-http feed on 127.0.0.1.
if [[ "$SU_FEED_URL" == http://127.0.0.1* ]]; then
    SPARKLE_KEYS+="
    <key>NSAppTransportSecurity</key><dict><key>NSAllowsLocalNetworking</key><true/><key>NSExceptionDomains</key><dict><key>127.0.0.1</key><dict><key>NSExceptionAllowsInsecureHTTPLoads</key><true/></dict></dict></dict>"
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>NotchDeck</string>
    <key>CFBundleIdentifier</key><string>com.coro.NotchDeck</string>
    <key>CFBundleName</key><string>NotchDeck</string>
    <key>CFBundleDisplayName</key><string>NotchDeck</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundleVersion</key><string>${BUILD}</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSAppleEventsUsageDescription</key>
    <string>NotchDeck reads and controls Music and Spotify to show Now Playing in the notch.</string>
    <key>NSCalendarsUsageDescription</key>
    <string>NotchDeck shows your upcoming events in the notch.</string>
    <key>NSCalendarsFullAccessUsageDescription</key>
    <string>NotchDeck shows your upcoming events in the notch.</string>
${SPARKLE_KEYS}
</dict>
</plist>
PLIST
plutil -lint "$APP/Contents/Info.plist" >/dev/null

# Sign inside out (no --deep): Sparkle's helpers, the framework, the Now Playing dylib, then the app.
SIGN=(codesign --force --sign "$SIGN_ID")
if [[ "$SIGN_ID" != "-" ]]; then
    if (( RELEASE )); then SIGN+=(--options runtime --timestamp); else SIGN+=(--options runtime --timestamp=none); fi
fi
FW="$APP/Contents/Frameworks/Sparkle.framework"
"${SIGN[@]}" "$FW/Versions/B/Autoupdate"
"${SIGN[@]}" "$FW/Versions/B/Updater.app"
"${SIGN[@]}" "$FW"
"${SIGN[@]}" "$APP/Contents/Resources/np/libnp.dylib"
"${SIGN[@]}" --entitlements packaging/entitlements.plist "$APP"
codesign --verify --deep --strict "$APP"
echo "Built $(pwd)/$APP ($VERSION/$BUILD, $([[ $RELEASE == 1 ]] && echo release || echo dev), signed by ${SIGN_ID:0:12}…)"
