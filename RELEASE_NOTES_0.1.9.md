# BetterStreamflix iOS 0.1.9

Faster stream startup — closer to Android’s first-play path.

- Play the first resolved source immediately (no settle wait; discovery continues in background)
- Skip pre-play `isPlayable` / HLS quality probes; probe qualities after playback starts
- Shorter prepare timeout (3.5s) and hoster HTTP timeouts; race meinecloud mirrors in parallel
- DE path: HTML page cache, SerienStream working-domain persist, parallel wrapper expand, fewer serial Kinoger expands
- Matching quality and 0.1.8 full-bleed artwork unchanged
- Version 0.1.9
