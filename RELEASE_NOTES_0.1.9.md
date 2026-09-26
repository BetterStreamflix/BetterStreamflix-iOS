# BetterStreamflix iOS 0.1.9

Faster stream startup — closer to Android’s first-play path — plus Featured hero/glass polish.

- Play the first resolved source immediately (no settle wait; discovery continues in background)
- Skip pre-play `isPlayable` / HLS quality probes; probe qualities after playback starts
- Shorter prepare timeout (3.5s) and hoster HTTP timeouts; race meinecloud mirrors in parallel
- DE path: HTML page cache, SerienStream working-domain persist, parallel wrapper expand
- Featured/Detail heroes: GeometryReader full-bleed fill; landscape backdrop preferred (no letterbox voids / strip crops)
- Featured CTAs: Liquid Glass View Details + compact add control (`glassEffect` / GlassEffectContainer)
- Matching quality and artwork fill preserved from 0.1.5 / 0.1.8 intent
- Version 0.1.9
