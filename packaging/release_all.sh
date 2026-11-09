#!/bin/bash
# One-shot release run for NotchDeck. Run it in a Terminal window on the Mac that holds the
# Developer ID certificate, with the login keychain unlocked (a GUI Terminal, not SSH):
#
#   NOTARY_PROFILE=<profile> packaging/release_all.sh
#
# Steps: keychain check -> Sparkle "notch" update key (+ private backup in ~/.notch-keys) ->
# release build 1.0.0 -> DMG -> notarize -> staple -> checks -> launch test from the DMG ->
# appcast.xml -> throwaway 1.0.1 local update test. Nothing is uploaded or published.
# macOS may show keychain prompts for generate_keys / sign_update: click "Always Allow".
#
# Env: NOTARY_PROFILE (required), SKIP_UPDATE_TEST=1 to skip the 1.0.1 test.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$(pwd)"
: "${NOTARY_PROFILE:?set NOTARY_PROFILE to your notarytool keychain profile}"
LOG="$ROOT/dist/release_all.log"
mkdir -p dist
exec > >(tee "$LOG") 2>&1
step() { printf '\n==> %s\n' "$*"; }

step "Keychain check"
ID="$(security find-identity -v -p codesigning | grep -m1 '"Developer ID Application:' | awk '{print $2}')"
[[ -n "$ID" ]] || { echo "No Developer ID Application identity in the keychain."; exit 1; }
T="$(mktemp -d)"; cp /bin/ls "$T/t"
codesign --force --sign "$ID" --timestamp --options runtime "$T/t" || {
    echo "codesign cannot use the key. Run: security unlock-keychain ~/Library/Keychains/login.keychain-db"; exit 1; }
xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null || {
    echo "notarytool profile $NOTARY_PROFILE not usable."; exit 1; }
echo "OK: signing and notary profile work."

step "Fetch Sparkle tools (swift build)"
swift build -c release >/dev/null
BIN="$ROOT/.build/artifacts/sparkle/Sparkle/bin"
[[ -x "$BIN/generate_keys" ]] || { echo "Sparkle tools missing in $BIN"; exit 1; }

step "Sparkle update key (account: notch)"
if PUB="$("$BIN/generate_keys" --account notch -p 2>/dev/null)" && [[ -n "$PUB" ]]; then
    echo "Existing notch key found; reusing it."
else
    "$BIN/generate_keys" --account notch >/dev/null
    PUB="$("$BIN/generate_keys" --account notch -p)"
fi
printf '%s\n' "$PUB" > packaging/sparkle_public_key.txt
echo "Public key written to packaging/sparkle_public_key.txt"
mkdir -p ~/.notch-keys && chmod 700 ~/.notch-keys
BACKUP=~/.notch-keys/notch_sparkle_ed25519_private.key
if [[ ! -s "$BACKUP" ]]; then
    "$BIN/generate_keys" --account notch -x "$BACKUP" >/dev/null
fi
chmod 600 "$BACKUP"
echo "Private key backup: $BACKUP (600). Keep a second copy somewhere offline; never commit it."

step "Release build 1.0.0"
VERSION=1.0.0 BUILD=1 ./build.sh --release
codesign --verify --deep --strict -v NotchDeck.app
codesign -d --entitlements - NotchDeck.app 2>/dev/null | grep -E 'apple-events|calendars' || true
codesign -dvv NotchDeck.app 2>&1 | grep -E 'Authority=Developer ID Application|flags=|Timestamp='

step "DMG + notarize + staple"
NOTARY_PROFILE="$NOTARY_PROFILE" packaging/make_dmg.sh
DMG="dist/NotchDeck-1.0.0.dmg"

step "Checks on the stapled DMG"
codesign --verify --deep --strict -v "$DMG"
spctl --assess --type open --context context:primary-signature -vv "$DMG"
MNT="$(mktemp -d)"
hdiutil attach -nobrowse -readonly -mountpoint "$MNT" "$DMG" >/dev/null
codesign --verify --deep --strict -v "$MNT/NotchDeck.app"
spctl --assess --type execute -vv "$MNT/NotchDeck.app"
ls -la "$MNT"

step "Launch test from the mounted DMG"
pkill -x NotchDeck 2>/dev/null || true; sleep 1
open "$MNT/NotchDeck.app"; sleep 6
if pgrep -x NotchDeck >/dev/null; then echo "OK: NotchDeck is running from the DMG."; else echo "FAIL: NotchDeck did not stay running."; fi
pgrep -fl 'np/run.pl' || echo "NOTE: Now Playing helper not running (it starts when the Now Playing module is enabled)."
echo "Now Playing helper output (play something first for a non-empty track):"
NP_OUT="$( (/usr/bin/perl "$MNT/NotchDeck.app/Contents/Resources/np/run.pl" \
    "$MNT/NotchDeck.app/Contents/Resources/np/libnp.dylib" np_stream & P=$!; sleep 3; kill $P) 2>&1 | head -1 | cut -c1-200)"
echo "${NP_OUT:-<no output>}"
pkill -x NotchDeck 2>/dev/null || true; sleep 1
hdiutil detach -force "$MNT" >/dev/null

step "appcast.xml for 1.0.0"
packaging/make_appcast.sh "$DMG" packaging/notes/1.0.0.html dist/appcast.xml
shasum -a 256 "$DMG" | tee dist/NotchDeck-1.0.0.dmg.sha256

if [[ "${SKIP_UPDATE_TEST:-0}" != 1 ]]; then
    step "Throwaway update test: a 1.0.0 test copy with a local feed offering 1.0.1"
    TEST="$(mktemp -d)"; PORT=8765
    # 1.0.1 (build 2), packed + signed with the notch key, served locally. Not notarized, never published.
    VERSION=1.0.1 BUILD=2 ./build.sh --release >/dev/null
    mkdir -p "$TEST/feed"
    NOTARIZE=0 packaging/make_dmg.sh >/dev/null
    mv dist/NotchDeck-1.0.1.dmg "$TEST/feed/"
    URL_BASE="http://127.0.0.1:$PORT" packaging/make_appcast.sh "$TEST/feed/NotchDeck-1.0.1.dmg" \
        packaging/notes/1.0.0.html "$TEST/feed/appcast.xml"
    # A 1.0.0 copy whose feed is the local server.
    SU_FEED_URL="http://127.0.0.1:$PORT/appcast.xml" VERSION=1.0.0 BUILD=1 ./build.sh --release >/dev/null
    mv NotchDeck.app "$TEST/NotchDeck.app"
    (cd "$TEST/feed" && exec python3 -m http.server "$PORT" --bind 127.0.0.1) > "$TEST/http.log" 2>&1 &
    SRV=$!; sleep 1
    defaults delete com.coro.NotchDeck SULastCheckTime 2>/dev/null || true
    open "$TEST/NotchDeck.app"
    echo "Waiting up to 60 s for Sparkle to fetch the local feed..."
    for _ in $(seq 60); do grep -q 'GET /appcast.xml' "$TEST/http.log" && break; sleep 1; done
    if grep -q 'GET /appcast.xml' "$TEST/http.log"; then echo "OK: Sparkle fetched the local feed."; else echo "Sparkle did not fetch the feed by itself; triggering Check for Updates is manual (menu bar icon)."; fi
    echo "Look for the 'A new version of NotchDeck is available! (1.0.1)' window, then click 'Remind Me Later'."
    read -r -p "Did the 1.0.1 update window appear? [y/n] " SAW || SAW="?"
    echo "Update window seen: $SAW"
    grep 'GET' "$TEST/http.log" || true
    pkill -x NotchDeck 2>/dev/null || true
    kill "$SRV" 2>/dev/null || true
    rm -rf "$TEST"
    defaults delete com.coro.NotchDeck SULastCheckTime 2>/dev/null || true
    echo "1.0.1 test artifacts deleted."
    # Restore the real 1.0.0 release app in the working folder.
    VERSION=1.0.0 BUILD=1 ./build.sh --release >/dev/null
fi

step "Done"
echo "DMG:      $ROOT/$DMG"
echo "appcast:  $ROOT/dist/appcast.xml"
echo "sha256:   $(cut -d' ' -f1 dist/NotchDeck-1.0.0.dmg.sha256)"
echo "log:      $LOG"
echo "Nothing was uploaded. Upload the DMG to the GitHub release, then publish the appcast."
