## BetterStreamflix 0.0.6

Featured CTA hit targets, title logos, Detail back placement, and a real public update feed.

### Fixes

- **Featured CTAs** — View Details and My List are equal 48pt capsules; the whole My List control is tappable (not only the + glyph)
- **Title logos** — Prefer raster TMDB clear logos (skip SVG), try multiple candidates; Featured + Detail show logos when TMDB has them
- **Detail back** — Raised closer to the status bar
- **Check for Updates** — Functional system: fetches a public feed JSON (no app PAT), version/build compare, up-to-date vs update-available, Download opens the release page; primary CTAs use full-height padded chrome (no crushed “View Releases”)
- **CI** — Publishes `ios/latest.json` to private BetterStreamflix-updates and public BetterStreamflix-update-feed

### Install

Download **BetterStreamflix-0.0.6-unsigned.ipa** from this release (or from the matching Actions artifact).
