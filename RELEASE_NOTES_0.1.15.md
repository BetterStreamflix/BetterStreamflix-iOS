# BetterStreamflix iOS 0.1.15

Stremio Configure actually works — wrong URLs, eager WebView capture, and nested sheets were breaking setup.

- **Configure URL:** Always opens `{addon-origin}/configure` (strips Debrid/token path segments that caused 404s after Install with Debrid)
- **WebView:** No longer cancels HTTPS SPA navigations on `manifest.json`; auto-installs only `stremio://`; HTTPS manifests need confirm tap
- **looksConfigured:** Comet opaque base64 configs recognized — no more permanent “needs configuration” skip after install
- **Install with Debrid:** Torrentio/Comet/TorBox only; MediaFusion/AIOStreams/Annatar/Jackettio open Configure instead of inventing broken URLs; TorBox requires a TorBox token
- **UX:** Configure via fullScreenCover (not nested sheet); Configure buttons on presets + Addon Store; clearer fallback copy
- **Paste:** `stremio:///https://…` and `/configure` URLs parse correctly
- Version 0.1.15
