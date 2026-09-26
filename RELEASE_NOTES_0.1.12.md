# BetterStreamflix iOS 0.1.12

Stremio mega polish — Debrid-first playback, full protocol hardening, and discovery that matches desktop expectations.

- **Debrid-first:** Real-Debrid / AllDebrid / Premiumize / TorBox tokens (Keychain) + one-tap Torrentio / Comet / MediaFusion install with your profile — no in-app BitTorrent
- Honest stream presets, empty-state diagnostics (no IMDb / torrents-only / addon down), WatchHub external-link clarity, unified “Stremio” naming
- Protocol: `tmdb:` (and kitsu) stream IDs, resource type/idPrefix guards, `configurationRequired` skip + Configure flow, optional meta enrichment for details/episodes
- Catalog: genre chips, skip pagination, parallel loads, Movies/Series shelves, global Search merge, lazy Home shelves, addon logos, adult opt-in, ETag disk cache, smoke health
- Deep-link install (`betterstreamflix://` / `stremio://`), addon list export/import, curated Addon Store browser, Torrentio mirror paste list
- Performance knobs (timeout / max parallel), stream query fail-fast, health-aware addon priority
- Version 0.1.12
