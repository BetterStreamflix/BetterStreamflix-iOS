# BetterStreamflix iOS 0.1.14

Hard playback + Stremio reliability fix — Debrid streams and NativePlayer discovery no longer die on false “no stream” / rejected sources.

- **Debrid HTTP kept:** Extensionless Real-Debrid / AllDebrid download URLs with `filename: ….mkv` are no longer dropped by the format filter (only literal `.mkv` path URLs stay unsupported)
- **Magnet → HTTP lives long enough:** Prepare budget 18s for Debrid unrestrict (was 3.5s); initial discovery wait 20s; race prefers cached / Debrid rows first (up to 14)
- **Honest torrent handling:** Torrents wrapped via Debrid no longer inflate “skipped torrent”; magnet URLs without `infoHash` parse `btih`; RD library short-circuit before addMagnet
- **Stremio protocol:** Stream-resource `idPrefixes` / types merged on install; refresh reuses the same prefixes; session cache keys include Debrid + addon fingerprint; config skip only for Debrid-shaped addons
- **Subtitles:** One failing Stremio subtitle addon no longer wipes the whole Stremio sub stack
- **DE scrapers:** SerienStream Cloudflare gate soft-fails (`noStream`) instead of hard provider errors; KinoGer tries `kinoger.fun` / `.to` / `.com` with working-origin memory
- Version 0.1.14
