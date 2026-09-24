## BetterStreamflix 0.0.7

Detail logo parity, sticky chrome, Featured / Support polish, first-launch setup, release history, and player reliability.

### Detail & Featured

- **Title logos** — Detail uses the same shared presentation pipeline and in-memory cache as Featured, so logos no longer fall back to text when Featured already has one
- **Back control** — Heavily polished glass chevron with true top-leading safe-area placement
- **Sticky header** — Scroll past the logo to reveal a compact bar with Back on the left and the media logo centered
- **Play / My List** — Smaller Play control; My List matches height and hit area as a labeled capsule
- **Featured CTAs** — Polished View Details + Add to List with a stronger add animation; watchlist toast sits lower above the tab bar

### Updates, Support, Setup

- **Browse release history** — Second high-quality sheet lists public releases with open/download actions (`ios/releases.json`)
- **Support CTAs** — Coffee / Telegram / Discord / Patreon redesigned with clearer hierarchy
- **First-launch setup** — Onboarding for theme, playback preferences, and providers; main catalog path is TMDB-only; Advanced exposes StreamingCommunity domain + playback sources; revisit from Settings

### Player & CI

- **Player** — Faster stalled-stream recovery, failure debounce, reconnect chrome for preparing/recovering only (no mid-buffer overlay spam), clearer retry copy
- **CI** — Publishes `ios/latest.json` and appends `ios/releases.json` on both update-feed repos

### Install

Download **BetterStreamflix-0.0.7-unsigned.ipa** from this release (or from the matching Actions artifact).
