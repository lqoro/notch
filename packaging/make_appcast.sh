#!/bin/bash
# Writes the Sparkle update feed (appcast.xml) for one NotchDeck release.
#
#   packaging/make_appcast.sh dist/NotchDeck-1.0.0.dmg notes.html ../notch-site/appcast.xml
#
# Signs the disk image with the "notch" EdDSA key in this Mac's login keychain (Sparkle's
# generate_keys --account notch). Set SPARKLE_BIN to the folder holding Sparkle's sign_update
# (default: the copy SwiftPM fetched). Set URL_BASE to serve the image from somewhere else
# (a local test server); default is the GitHub release for that version.
#
# Order matters: upload the DMG to the GitHub release first, then publish the feed.
set -euo pipefail
DMG="${1:?usage: make_appcast.sh <dmg> <notes.html> <out appcast.xml>}"
NOTES="${2:?notes html fragment}"
OUT="${3:?output path}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SPARKLE_BIN="${SPARKLE_BIN:-$ROOT/.build/artifacts/sparkle/Sparkle/bin}"
[[ -x "$SPARKLE_BIN/sign_update" ]] || { echo "sign_update not found in $SPARKLE_BIN (set SPARKLE_BIN)" >&2; exit 1; }

# Read the version from the app inside the image, so the feed can never promise a different one.
MNT="$(mktemp -d)"
hdiutil attach -nobrowse -readonly -mountpoint "$MNT" "$DMG" >/dev/null
trap 'hdiutil detach -force "$MNT" >/dev/null 2>&1 || true; rmdir "$MNT" 2>/dev/null || true' EXIT
PL="$MNT/NotchDeck.app/Contents/Info.plist"
SHORT="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PL")"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$PL")"
MINOS="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$PL")"
hdiutil detach -force "$MNT" >/dev/null; trap - EXIT; rmdir "$MNT" 2>/dev/null || true

NAME="$(basename "$DMG")"
[[ "$NAME" == "NotchDeck-$SHORT.dmg" ]] || { echo "$NAME does not match app version $SHORT" >&2; exit 1; }
BASE="${URL_BASE:-https://github.com/lqoro/notch/releases/download/v$SHORT}"
SIGLINE="$("$SPARKLE_BIN/sign_update" --account notch "$DMG")"
SIG="$(sed -nE 's/.*sparkle:edSignature="([^"]+)".*/\1/p' <<<"$SIGLINE")"
LEN="$(sed -nE 's/.*length="([0-9]+)".*/\1/p' <<<"$SIGLINE")"
[[ -n "$SIG" && "$LEN" == "$(stat -f%z "$DMG")" ]] || { echo "sign_update output unexpected" >&2; exit 1; }
NOTES_HTML="$(cat "$NOTES")"
[[ "$NOTES_HTML" != *"]]>"* ]] || { echo "notes may not contain ]]>" >&2; exit 1; }

mkdir -p "$(dirname "$OUT")"
cat > "$OUT" <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>NotchDeck for Mac</title>
    <link>https://notch.lqoro.com</link>
    <description>Updates for NotchDeck.</description>
    <language>en</language>
    <item>
      <title>NotchDeck $SHORT</title>
      <pubDate>$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S GMT')</pubDate>
      <sparkle:version>$BUILD</sparkle:version>
      <sparkle:shortVersionString>$SHORT</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>$MINOS</sparkle:minimumSystemVersion>
      <description><![CDATA[$NOTES_HTML]]></description>
      <enclosure url="$BASE/$NAME"
                 sparkle:edSignature="$SIG" length="$LEN"
                 type="application/x-apple-diskimage"/>
    </item>
  </channel>
</rss>
XML
xmllint --noout "$OUT"
echo "Wrote $OUT for NotchDeck $SHORT (build $BUILD, $LEN bytes, signed)"
