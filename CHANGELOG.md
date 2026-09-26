# Changelog

## 1.1.5 - 2026-09-25

- The calendar and settings state files are now read through a size- and
  shape-checked parser. Content over the cap, malformed JSON, and JSON that is
  not an object are ignored instead of being loaded, and a bad cache file no
  longer replaces what the panel is already showing.
- curl is now run with `-q`, so a `~/.curlrc` can no longer add options to the
  plugin's requests.
- Responses are parsed and cached only when curl exits successfully. A failed
  request is retried as before and never overwrites the cache.

## 1.1.4 - 2026-09-25

- Race, circuit, and location strings from the calendar API now always render
  as plain text, so a crafted response can no longer be interpreted as rich
  text by the shell. The footer credit is plain text too, which drops the
  Open-Meteo link (both projects are credited in the README).
- Calendar and weather responses are capped at 64 KB. Past that, curl aborts
  the transfer and the panel keeps showing the last cached response instead of
  growing the shell's memory or the cache file.
- The background refresh is now once a day instead of every 30 minutes, with
  one fetch when the panel loads. A 1.5-second poll timer that only ever fired
  once, at startup, is gone. Opening the panel or middle-clicking still
  refreshes immediately.

## 1.1.3 - 2025-09-08

- Fixed panel positioning: the popup now anchors under the bar icon instead of centering on screen.

## 1.1.2 - 2026-09-08

- Fixed panel close after Omarchy 4.0.3: the new `PluginBarApi` facade exposes
  `centerHoverRevealSuppressed` as read-only, so the direct assignment inside
  `setCenterHoverRevealSuppressed()` threw a `TypeError` and left the popup
  stuck open until restart. The call now goes through the shared
  `setCenterHoverRevealSuppressed()` method when available, with the writable
  property as a fallback.

## 1.1.1 - 2026-08-22

- Refreshed preview image.

## 1.1.0 - 2026-08-22

- Theme-dynamic text colors throughout the panel: emphasis now renders at full
  theme foreground, secondary text uses the theme's `muted` role, and raw
  `Color.accent` is reserved for small decorations (clock glyph, track dot,
  direction arrow). Replaces the hardcoded darkening ladder and the
  selected-state-derived accent that rendered near-invisible on some themes.
- Sessions in progress are no longer skipped: each series config carries
  typical running windows (minutes), a started event stays the countdown
  target until it plausibly ends, the bar pill shows "live now", and the hero
  line reads e.g. "Qualifying · live".
- Weekend schedule rows use natural capitalization ("Race" instead of "RACE").
- LICENSE trimmed to pure MIT for GitHub license auto-detection; third-party
  data attributions live in README.md.

## 1.0.0 - Initial release

- Bar pill with countdown to the next Formula 1 session, fed by Jolpica F1.
- Panel with next-race hero (season, round, name, locality), track diagram
  with start/finish marker and direction of travel, circuit weather from
  Open-Meteo, local/track time toggle, and full weekend schedule.
- Season rollover: once every race has run, the countdown hops to the next
  season's opening round.
- Offline resilience via cached calendar responses.
