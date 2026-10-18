# WashTower Widget

A macOS desktop widget (and menu bar countdown) for LG ThinQ washers and dryers. It was built for an LG WashTower but works with any washer or dryer on your ThinQ account.

- Live countdowns that tick every second, plus a progress bar and the expected finish time for each drum
- Small and medium desktop widgets; choose to show both drums, only the washer, or only the dryer
- Optional menu bar countdown (`W 0:45  D 1:28`) with a dropdown for details
- Works anywhere your Mac has internet, at home or not
- Universal app for Apple silicon and Intel Macs on macOS 14 Sonoma or later

## How it works

LG appliances don't offer a local API. A WashTower has no open ports on your network and only talks over encrypted MQTT to LG's cloud. So this app uses LG's official [ThinQ Connect API](https://thinq.developer.lge.com/en/cloud/docs/thinq-connect/), authenticated with a personal access token you create for your own LG account.

- **The app** runs in the menu bar. It checks ThinQ every minute while a cycle is running (every two minutes otherwise) and tells the widget to refresh when something changes.
- **The widget** shows the latest state. Its countdown and progress bar animate on their own between updates. It can also fetch state by itself if the app isn't running, but macOS limits how often widgets refresh, so updates will be slower.

The app talks only to LG's API (`api-{aic,eic,kic}.lgthinq.com`). Nothing else is collected or sent.

## Setup

### 1. Create a ThinQ token

1. Sign in at [connect-pat.lgthinq.com](https://connect-pat.lgthinq.com) with the account your ThinQ app uses.
2. Choose **ADD NEW TOKEN** and give it a name.
3. Select only **Permission to view all devices** and **Permission to view all device statuses**. The app never controls your appliances.
4. Choose **CREATE TOKEN** and copy it.

### 2. Build

You'll need Xcode 26 or later and an Apple ID signed in to Xcode. The free Personal Team works.

```bash
git clone https://github.com/joshmiller83/washtower-widget.git
cd washtower-widget
cp Config/Local.xcconfig.example Config/Local.xcconfig
```

Edit `Config/Local.xcconfig`:

- `DEVELOPMENT_TEAM` is your Team ID. Find it in Xcode › Settings › Accounts › your team, or in the `OU=` field of `security find-identity -v -p codesigning`.
- `BUNDLE_ID_PREFIX` is any reverse-DNS prefix you own, e.g. `com.yourname`.

Then either open `WashTowerWidget.xcodeproj` and run, or build a universal release:

```bash
./scripts/build-release.sh
```

This writes `build/Release/WashTower Widget.app` and `dist/WashTower-Widget.zip`.

### 3. Install

Move **WashTower Widget.app** to `/Applications` and open it. The Settings window opens on first launch:

1. Paste your token, check the country code, and choose **Save and Test**. Your washer and dryer should be listed.
2. Turn on **Open at login** so the widget stays up to date.
3. Right-click the desktop, choose **Edit Widgets…**, search for **WashTower**, and drag a widget onto the desktop.

### Installing on another Mac

Copy `dist/WashTower-Widget.zip` to the other Mac (AirDrop works), unzip it, and move the app to `/Applications`. The build isn't notarized, so macOS blocks the first launch. Either right-click the app and choose **Open**, or run:

```bash
xattr -dr com.apple.quarantine "/Applications/WashTower Widget.app"
```

Then paste the same token into Settings on that Mac. Each Mac talks to LG on its own.

## Troubleshooting

- **The widget isn't in the gallery.** The app must be in `/Applications` and opened at least once. Try logging out and back in.
- **"ThinQ rejected the token."** Tokens can be revoked or expire. Create a new one and paste it into Settings.
- **Field names look wrong for your model.** `tools/washtower.py raw` dumps the raw ThinQ state from the command line, so you can check what your machine reports (`python3 tools/washtower.py --help` for setup).

## Project layout

| Path | What's there |
| --- | --- |
| `Shared/` | ThinQ API client, state parsing, and the App Group store used by both targets |
| `App/` | Menu bar app: polling, settings, menu dropdown |
| `Widget/` | WidgetKit extension |
| `project.yml` | [XcodeGen](https://github.com/yonaskolb/XcodeGen) spec; the generated `.xcodeproj` is committed |
| `tools/washtower.py` | Dependency-free Python CLI for the same API |

## Credits

The API details (regional hosts, headers, client key) come from LG's official open-source SDK, [thinq-connect/pythinqconnect](https://github.com/thinq-connect/pythinqconnect). This project isn't affiliated with or endorsed by LG Electronics. "LG", "ThinQ", and "WashTower" are trademarks of LG Electronics.

## License

MIT
