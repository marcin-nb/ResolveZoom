# Changelog

All notable changes to ResolveZoom are documented here.

## [0.4] — 2026-08-08

The headline of this release is a memory leak that made the app grow without bound
during long editing sessions. Several gesture bugs were fixed along the way.

### Fixed

- **Unbounded memory growth (the big one).** Every scroll and pinch event passing
  through the event tap was retained and never released. During sustained trackpad
  use this leaked thousands of events per minute — users reported the app climbing
  from ~22 MB to 60 MB, and in one long session to several GB, with memory only
  returning to normal after a restart. Memory now stays flat regardless of how long
  the app runs. ([reported on YouTube])

- **Runaway permission dialog.** If Accessibility permission was revoked while the
  app was running, a watchdog timer and a re-check timer kept re-triggering each
  other, spawning a new permission window every two seconds indefinitely. The app
  now shows exactly one window and reuses it.

- **Direction-reversal filter never ran.** The check meant to discard rapid pinch
  direction flips compared a timestamp against itself, so it was always true and the
  filter was dead code. Rapid reversals were passed straight through to Resolve as
  alternating zoom in/out, which felt like the timeline stretching and folding
  erratically. ([#1])

- **Interference while dragging.** The app no longer acts on pinch gestures while a
  mouse button is held. Previously a stray pinch during a drag — for example pulling
  a clip into the timeline — injected Option-flagged scroll events into the active
  drag, which Resolve reinterpreted as a modified drag. Reported as clips stretching
  and folding and the cursor jumping between positions. ([#1])

- **Slow pinches dropped at low sensitivity.** The computed scroll delta was
  truncated to a whole number, so any movement below one pixel was discarded
  entirely and the gesture appeared to stall. The fractional remainder now carries
  forward between events.

- **Stale status text.** The menu bar status was only recalculated when another app
  was activated, and opening ResolveZoom's own menu or Preferences counted as an
  activation — which could leave the status stuck on "Waiting for Resolve…" while
  Resolve was in active use. The status is now recalculated when the menu opens, and
  the app ignores itself when tracking the frontmost application. ([#2])

### Added

- **Diagnostics in the menu.** The menu now shows which application the app sees as
  frontmost, which bundle identifier it is matching against, how many pinch events
  have been seen and acted on, the last magnitude read, and why the last event was
  skipped. If something isn't working, this line says what.

- **Manual Resolve selection.** "Select DaVinci Resolve…" lets you point at the
  Resolve application directly; the app reads its bundle identifier and pins it.
  "Use automatic detection" reverts. Auto-detection is unchanged for everyone else —
  this is an escape hatch for unusual installs and beta builds, not a setup step.

### Changed

- DaVinci Resolve is now matched by bundle-identifier prefix rather than one exact
  string, so Studio editions and beta builds are recognised without a code change.
- Reduced per-event overhead in the gesture path: settings and the frontmost
  application are read once and cached instead of being looked up on every event
  (60–120 times per second during a pinch), and the callback drains autoreleased
  objects immediately.
- The version shown in the menu is read from the bundle instead of being hardcoded.

### Notes

Tested on macOS 26 Tahoe with DaVinci Resolve 21.0.4. Memory was verified to stay
flat across extended pinching and repeated permission grant/revoke cycles.

[#1]: https://github.com/marcin-nb/ResolveZoom/issues/1
[#2]: https://github.com/marcin-nb/ResolveZoom/issues/2
[reported on YouTube]: https://github.com/marcin-nb/ResolveZoom

## [0.3]

Initial public release.
