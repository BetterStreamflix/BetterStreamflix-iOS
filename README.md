# BetterStreamflix for iOS

Native SwiftUI client for BetterStreamflix — browse, detail, playback, library, watchlist, continue watching, and settings.

## Requirements

- macOS with Xcode 16.4+ (iOS 18 SDK; iOS 26 SDK enables system Liquid Glass APIs)
- iOS / iPadOS 18+
- Apple Developer account for physical-device installs

No third-party Swift packages are required.

## Open & run

1. Clone this repository.
2. Open `BetterStreamflix.xcodeproj` in Xcode.
3. Select the **BetterStreamflix** scheme and an iPhone simulator or device.
4. Under **Signing & Capabilities**, choose your Team. If the bundle id `com.betterstreamflix.ios` conflicts, change it to a unique value.
5. Press **Run**.

## Version

Current marketing version: **0.1.12**. CI advances the build number on each release.

## Unsigned IPA (GitHub Actions + Releases)

Every push to `main` runs **Unsigned IPA** (`.github/workflows/unsigned-ipa.yml`):

1. Builds an unsigned IPA via `./build-unsigned-ipa.sh`
2. Uploads the Actions artifact
3. Publishes a GitHub Release `v{version}` with the IPA attached
4. Writes `ios/latest.json` to the private [BetterStreamflix-updates](https://github.com/BetterStreamflix/BetterStreamflix-updates) bookkeeping repo **and** the public [BetterStreamflix-update-feed](https://github.com/BetterStreamflix/BetterStreamflix-update-feed) the app reads (no PAT in the app)

### Download

- **Actions:** repo → Actions → Unsigned IPA → download the artifact
- **Releases:** [Releases](https://github.com/BetterStreamflix/BetterStreamflix-iOS/releases) → download the `.ipa`

### In-app Check for Updates

**More → Check for updates** (or Settings → About) fetches the public feed at
`https://raw.githubusercontent.com/BetterStreamflix/BetterStreamflix-update-feed/main/ios/latest.json`,
compares version/build, and offers Download / up-to-date / retry states. No personal access token is embedded in the app.

Locally: `./build-unsigned-ipa.sh 0.1.12`.

## Features

- Cinematic Home hero with Liquid Glass action cluster, Continue Watching, Watchlist feedback, and TMDB shelves
- **Stremio** — Debrid-first community plugins (catalog / stream / subtitles), install-by-URL + deep links, one-tap Debrid presets, hub/Movies/Series/Search shelves, health + smoke, Addon Store; built-in HTTP is Core-only (not listed as a plugin)
- Library tab (Continue / Watchlist / Watched) with glass empty states
- Movies & Series catalogs, Search with glass recent chips
- Detail with tapable cast → full actor profiles, seasons/episodes, Play / My List
- Logo-only splash; branded About support CTAs (Coffee, Telegram, Discord, Patreon)
- AVPlayer HLS with source/quality, double-tap ±10s, volume/brightness pans, glass controls, PiP / AirPlay
- Settings / About: themes, languages, Stremio plugins + Debrid, backup, updates via Releases, community CTAs, credits

## Legal

The app does not host media. Only access content you are legally authorized to view. See `LICENSE` (Apache-2.0) and `NOTICE`.
