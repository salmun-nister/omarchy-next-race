# Changelog

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
