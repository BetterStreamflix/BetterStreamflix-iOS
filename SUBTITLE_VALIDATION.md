# Native subtitle playback validation

Use a physical iPhone or iPad. In Xcode's console, filter for `SUBTITLE PERF` and
`SUBSYNC`. Test both **Fast** (the default) and **Complete Before Playback** under
Settings → Subtitle Loading.

1. Play an HLS title with a built-in Hebrew subtitle. Confirm playback starts
   without subtitle-segment downloads, and that the track appears in AVPlayer's
   native subtitle menu.
2. Play a title with a cold third-party Hebrew subtitle. Confirm subtitle
   preparation releases the initial player item within five seconds, even if
   the provider stalls. Video buffering may take additional network time. If
   the track arrives later, confirm there is at most one
   automatic player-item enrichment, without a visible jump or lost play/pause
   state.
3. Replay the same movie or episode. Confirm a `cache FRESH` trace and no
   subtitle-file download for the unchanged track. A new signed subtitle URL
   should still reuse the cached cues.
4. Select the injected third-party track in the native AVPlayer subtitle menu.
   Confirm it renders fullscreen and in Picture in Picture; enter and leave PiP,
   seek, pause/resume, and background/foreground the app while playback continues.
5. Change video source. Confirm the position, speed, audio language, quality
   intent, and subtitle choice survive. Native tracks from the old source must
   disappear; native tracks from the new source must appear. Third-party cues
   should not be downloaded again.
6. Switch subtitles, turn subtitles off, and turn them back on. Confirm the
   remembered track and saved resync version are restored. Deleting a saved
   version should fall back to its base track.
7. Open Subtitle Studio for a third-party track, then a built-in HLS track.
   Third-party cues should come from cache; native cue-segment requests should
   begin only after Studio opens. Save a sync adjustment and replay the title.
8. Export and import user data. Confirm the remembered subtitle choice returns
   but subtitle cue-cache files are not included in the backup.

Expected traces: `video source PUBLISHED` is followed by `PlayerSession LOAD
START` promptly (target: within one second). A native preferred track should
add near-zero preparation time, a fresh cache hit should normally finish within
one second, and a cold preferred external track must not hold Fast-mode startup
past the five-second budget. Other provider work remains in the background.

Direct progressive MP4 sources currently cannot expose BetterStreamflix-injected external
subtitles as native AVPlayer media-selection tracks. Their video starts without
an empty HLS wrapper; validate native injection with HLS sources until a proper
fragmented-MP4/HLS packaging path is implemented.
