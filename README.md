# BetterStreamflix for iOS

Native SwiftUI client for BetterStreamflix — browse, detail, playback, library, watchlist, continue watching, and settings.

## Requirements

- macOS with Xcode 16 or newer (iOS platform installed in **Xcode → Settings → Components**)
- iOS / iPadOS 17+
- Apple Developer account for physical-device installs

No third-party Swift packages are required.

## Open & run

1. Clone this repository.
2. Open `BetterStreamflix.xcodeproj` in Xcode.
3. Select the **BetterStreamflix** scheme and an iPhone simulator or device.
4. Under **Signing & Capabilities**, choose your Team. If the bundle id `com.betterstreamflix.ios` conflicts, change it to a unique value.
5. Press **Run**.

## Version

Current marketing version: **0.0.1**. CI advances the build number on each release.

## Unsigned IPA (GitHub Actions + Releases)

Every push to `main` runs **Unsigned IPA** (`.github/workflows/unsigned-ipa.yml`):

1. Builds an unsigned IPA via `./build-unsigned-ipa.sh`
2. Uploads the Actions artifact
3. Publishes a GitHub Release `v{version}` with the IPA attached
4. Updates the public feed at [BetterStreamflix-updates](https://github.com/BetterStreamflix/BetterStreamflix-updates) → `ios/latest.json`

### Download from Actions

1. Open [Actions](https://github.com/BetterStreamflix/BetterStreamflix-iOS/actions)
2. Open the latest **Unsigned IPA** run
3. Download `BetterStreamflix-0.0.1-unsigned` (or the matching version artifact)

### Download from Releases

Open [Releases](https://github.com/BetterStreamflix/BetterStreamflix-iOS/releases) and download the IPA asset from the latest tag.

In-app **Check for updates** reads the public JSON feed (no authentication).

Locally: `./build-unsigned-ipa.sh 0.0.1`.

The IPA is unsigned — install via your own signing/sideload flow.

## Features

- Cinematic Home hero, Continue Watching, Watchlist, and TMDB shelves
- Library tab (Continue / Watchlist / Watched)
- Movies & Series catalogs, Search with recent queries
- Detail with cast carousel, seasons/episodes, Play / My List
- AVPlayer HLS with source/quality, double-tap ±10s, volume/brightness pans, PiP / AirPlay
- Settings / About: themes, languages, backup, updates, community links, credits

## Legal

The app does not host media. Only access content you are legally authorized to view. See `LICENSE` (Apache-2.0) and `NOTICE`.
