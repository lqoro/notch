# NotchDeck

A small macOS utility that turns the MacBook notch into a panel. Hover over the notch and it
opens with tabs for what you're playing, your next events, a file shelf and more. On Macs
without a notch it shows a pill at the top of the built-in display.

Website: https://notch.lqoro.com

- macOS 14 Sonoma or later. Built and tested on Apple Silicon.
- Runs from the menu bar (no Dock icon). Settings and **Check for Updates…** live in the menu bar icon.
- Free and open source (MIT).

## Features

Each feature is a module you can turn on or off in Settings.

| Module | What it does |
| --- | --- |
| **Now Playing** | Track, artwork and play/pause/next/previous for Music and Spotify, plus any other player that reports to macOS Now Playing (browsers, iPad apps). |
| **Volume & Brightness HUD** | Replaces the stock volume/brightness overlay with one in the notch when you press the media keys. |
| **Calendar** | Your upcoming events. |
| **Notifications** | Recent Notification Center items, readable from the notch. You can optionally show only apps that aren't installed on this Mac (usually iPhone mirroring). |
| **Todos** | Shows a Markdown task list or JSON file you choose (default `~/todos.md`). Read-only: ticking a task only hides it inside NotchDeck. |
| **File Tray** | Drop files on the notch to keep them handy. Drag them out again, open them, reveal them in Finder, or AirDrop them all. |
| **Timer** | A countdown with a live readout in the closed notch. |
| **Battery** | Charge level, charging state and time remaining. |
| **Plugins** | Simple declarative tabs: put a folder with a `manifest.json` (title, text, link buttons) in `~/Library/Application Support/NotchDeck/Plugins`. These plugins can't run code. |

## Install

1. Download `NotchDeck-<version>.dmg` from [Releases](https://github.com/lqoro/notch/releases) or
   from https://notch.lqoro.com.
2. Open it and drag **NotchDeck** to **Applications**.
3. Open NotchDeck from Applications. Its icon appears in the menu bar.

The app is signed with a Developer ID and notarized by Apple. It checks for updates once a day
(through [Sparkle](https://sparkle-project.org)) and asks you before installing anything. You can
also check yourself with **Check for Updates…** in the menu.

## Permissions and why

NotchDeck asks for a permission only when a feature needs it. Everything stays on your Mac:
NotchDeck has no analytics and sends no data anywhere. Its only network traffic is the daily
update check and downloading album artwork for the current Spotify track from the URL Spotify provides.

| Permission | Used by | Why |
| --- | --- | --- |
| **Automation** (Music, Spotify) | Now Playing | Reads the current track and sends play/pause/skip. macOS asks the first time each player is used. |
| **Accessibility** | Volume & Brightness HUD | Needed to see the volume and brightness keys and draw the HUD in their place. Without it you get the stock HUD. |
| **Calendars** | Calendar | Reads your upcoming events. macOS asks when you tap Allow in the Calendar tab. |
| **Full Disk Access** | Notifications | Notification Center history is stored in a protected database that only Full Disk Access unlocks. NotchDeck opens it read-only. |
| Files you choose | Todos, File Tray | Only files you pick or drop. |

## Honest limits

- **System Now Playing uses a private API.** Since macOS 15.4, third-party apps can't read
  the system Now Playing info, which comes from the private `MediaRemote` framework. NotchDeck
  works around this by having Apple's own `/usr/bin/perl` load a tiny helper library
  (`Contents/Resources/np/libnp.dylib`) that reads MediaRemote and streams JSON back. It's a
  workaround, not a supported interface, and a future macOS update could break it. If that
  happens, Music and Spotify keep working through AppleScript, and other players simply won't
  show up.
- **Brightness** uses the private `DisplayServices` framework. Where that's unavailable, the
  brightness keys fall back to the stock HUD.
- **Notifications** can't tell which device an alert came from, because macOS doesn't record
  that. The "only apps not on this Mac" filter is a heuristic. Clearing an item only hides it
  inside NotchDeck.
- The notch panel is drawn on the built-in display only.
- Intel Macs aren't tested.

## Build from source

You need Xcode 16 or later (Swift 6 toolchain).

```bash
git clone https://github.com/lqoro/notch.git
cd notch
./build.sh            # dev build: NotchDeck.app, signed with your Apple Development identity
open NotchDeck.app
```

`build.sh` picks the first "Apple Development" signing identity in your keychain. Set
`SIGN_ID=<identity>` to choose one, or `SIGN_ID=-` for ad hoc. A stable identity keeps macOS's
Accessibility, Full Disk Access and Automation grants across rebuilds; ad-hoc signatures lose
them on every build. Dev builds don't include the update key, so Sparkle stays off.

### Release (maintainers)

```bash
./build.sh --release                                   # Developer ID, hardened runtime, timestamp
NOTARY_PROFILE=<profile> packaging/make_dmg.sh         # dist/NotchDeck-<version>.dmg, notarized + stapled
# upload the DMG to the GitHub release first, then:
packaging/make_appcast.sh dist/NotchDeck-<version>.dmg packaging/notes/<version>.html <site>/appcast.xml
```

`NOTARY_PROFILE=<profile> packaging/release_all.sh` does the build, DMG, notarization, checks,
appcast and a local update test in one go.

Set `VERSION` and `BUILD` to override the version (`CFBundleShortVersionString` and
`CFBundleVersion`). The public update key is in `packaging/sparkle_public_key.txt`. The private
key never goes in this repository.

## License

MIT, see [LICENSE](LICENSE). Third-party components are listed in
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
