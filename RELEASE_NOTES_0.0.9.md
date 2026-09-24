## BetterStreamflix 0.0.9

Detail sticky header flush under the status bar — real layout fix, not a nudge.

### Fix

- **Root cause** — 0.0.8 padded the *outer* chrome by the top safe-area inset, leaving a transparent gap above the material while the bar sat mid-hero. Safe-area padding now applies to the content row; the material background fills that padding so the bar is flush under the status bar / Dynamic Island.
- Floating and sticky backs still share one top-leading origin in that slim row; logo stays centered.

### Install

Download **BetterStreamflix-0.0.9-unsigned.ipa** from this release (or from the matching Actions artifact).
