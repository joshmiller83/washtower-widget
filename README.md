# WashTower Widget

A macOS desktop widget (and menu bar countdown) for LG ThinQ washers and dryers. It was built for an LG WashTower but works with any washer or dryer on your ThinQ account.

- Live countdowns that tick every second, plus a progress bar and the expected finish time for each drum
- Small and medium desktop widgets; choose to show both drums, only the washer, or only the dryer
- Optional menu bar countdown (`W 0:45  D 1:28`) with a dropdown for details
- Works anywhere your Mac has internet, at home or not
- Universal app for Apple silicon and Intel Macs on macOS 14 Sonoma or later
- Optional [iPhone app](#iphone-live-activity) with a Live Activity on the Lock Screen, Dynamic Island and Apple Watch, started automatically when a cycle begins

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

### 2. Download or build

The quickest option is to download `WashTower-Widget.zip` from the [latest release](https://github.com/joshmiller83/washtower-widget/releases/latest) and skip to step 3.

To build it yourself, you'll need Xcode 26 or later and an Apple ID signed in to Xcode. The free Personal Team works.

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

## iPhone Live Activity

The iPhone app shows the countdowns as a Live Activity: on the Lock Screen, in the Dynamic Island, in the Apple Watch Smart Stack, and in the menu bar of a Mac on macOS 26 with iPhone Mirroring. It starts by itself when a cycle begins and ends when the laundry's done, even if the app isn't open.

An iPhone can't poll LG in the background, so a small **relay** does it. It's a Swift server (`Relay/`) that runs on an always-on Mac. It polls ThinQ every minute and sends Live Activity pushes through Apple's push service (APNs). The phone reaches it over HTTPS, through a [Cloudflare Tunnel](https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/) in this setup.

You'll need:

- A **paid Apple Developer Program** membership. Push notifications don't work with the free Personal Team.
- An APNs auth key, the `.p8` file. Create it at developer.apple.com › Certificates, IDs & Profiles › Keys › **+**, and tick **Apple Push Notifications service (APNs)**. Apple lets you download it only once. Keep it out of the repo (`*.p8` is git-ignored).
- A Mac that stays on to run the relay, and a public HTTPS hostname that points at it.

### Relay

```bash
cp deploy/config.env.example deploy/config.env   # then fill it in: token file, hostname, APNs key
deploy/build.sh                                  # runs the tests, builds, stages the binary
sudo deploy/install-service.sh                   # installs a LaunchDaemon; rerun after editing config.env
deploy/tunnel-add-hostname.sh                    # optional: adds the hostname to an existing Cloudflare Tunnel
deploy/status.sh                                 # daemon, health, APNs, paired phones, last poll
```

The relay listens only on `127.0.0.1`. Every API call needs the relay key, which is created on first run and handed to the phone when you pair. For builds you install from Xcode, `APNS_ENV=development` is correct.

### Phone

1. Put your phone's ids in `Config/device.env` (see the top of `scripts/install-phone.sh`), then run `scripts/install-phone.sh`. It installs over USB or home Wi-Fi.
2. Run `deploy/pair.sh` on the relay Mac. It opens a QR code: scan it with the iPhone's Camera, open it in WashTower, and tap **Pair**.
3. Send a sample activity with `~/WashTowerRelay/bin/washtower-relay test-start` (run with the `WT_*` settings, as `deploy/status.sh` does). When it appears, tap **Allow** under it on the Lock Screen. iOS won't let the relay update or end activities it started until you allow them. End the sample with `test-end`.

## Troubleshooting

- **The widget isn't in the gallery.** The app must be in `/Applications` and opened at least once. Try logging out and back in.
- **"ThinQ rejected the token."** Tokens can be revoked or expire. Create a new one and paste it into Settings.
- **The Live Activity shows but never updates or ends.** Tap **Allow** under it on the Lock Screen, or turn on Live Activities for WashTower in Settings. Until then iOS doesn't give the app the token the relay needs. To watch the app's token handling, run `xcrun devicectl device process launch --console --device <id> <bundle id>`.
- **Field names look wrong for your model.** `tools/washtower.py raw` dumps the raw ThinQ state from the command line, so you can check what your machine reports (`python3 tools/washtower.py --help` for setup).

## Project layout

| Path | What's there |
| --- | --- |
| `Shared/` | ThinQ API client, state parsing, and the App Group store used by both targets |
| `App/` | Menu bar app: polling, settings, menu dropdown |
| `Widget/` | WidgetKit extension |
| `iOS/` | iPhone app and its Live Activity extension |
| `Relay/` | Swift package for the relay server (`swift test --package-path Relay`) |
| `deploy/` | Scripts that build, install, pair and check the relay |
| `project.yml` | [XcodeGen](https://github.com/yonaskolb/XcodeGen) spec; the generated `.xcodeproj` is committed |
| `tools/washtower.py` | Dependency-free Python CLI for the same API |

## Credits

The API details (regional hosts, headers, client key) come from LG's official open-source SDK, [thinq-connect/pythinqconnect](https://github.com/thinq-connect/pythinqconnect). This project isn't affiliated with or endorsed by LG Electronics. "LG", "ThinQ", and "WashTower" are trademarks of LG Electronics.

## License

MIT
