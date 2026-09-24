# BetterStreamflix for iOS

Native SwiftUI client for BetterStreamflix — browse, detail, playback, watchlist, continue watching, and settings with a polished streaming UI.

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

Optional: regenerate the Xcode project from `project.yml` with [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`xcodegen generate`).

## Features

- TMDB-backed home hero carousel and discovery shelves (trending, popular, top rated, genres)
- Native navigation: Home, Movies, Series, Search, Details, Seasons/Episodes, Watchlist, Continue Watching, Settings
- Multi-provider playback discovery with HLS via AVPlayer
- Source & quality picker, resume positions, next-episode handoff
- Subtitles (preferred languages, timing offset), audio language preference
- Picture in Picture, AirPlay, background audio
- Theme presets, JSON backup/restore of library and settings

## Architecture

`MediaProvider` isolates catalog/stream providers. Shared models (`MediaItem`, `PlaybackSource`, `SubtitleSource`) keep SwiftUI and AVPlayer provider-agnostic. Register providers in `AppEnvironment`.

Durable library data lives under Application Support/`BetterStreamflix`.

## Legal

The app does not host media. Only access content you are legally authorized to view. See `LICENSE` (Apache-2.0) and `NOTICE`.
