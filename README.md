# ResolveZoom

A lightweight macOS menu bar app that converts trackpad pinch gestures into timeline zoom in DaVinci Resolve.

DaVinci Resolve doesn't support pinch-to-zoom on the timeline out of the box. ResolveZoom runs silently in the background and intercepts pinch gestures, converting them into the standard Alt+Scroll zoom that Resolve understands — giving you fast, intuitive timeline navigation without touching the keyboard.

---

## Features

- **Pinch to zoom** — use your trackpad naturally to zoom the Resolve timeline
- **Adjustable sensitivity** — dial in the zoom speed that feels right for you
- **Invert zoom direction** — if the default direction feels backwards, flip it
- **Multi-monitor support** — works correctly across all display configurations, including Resolve's dual-screen mode
- **Launch at Login** — start automatically with macOS
- **Minimal footprint** — lives in the menu bar, uses no resources when Resolve isn't in focus

If ResolveZoom saves you time, consider buying me a coffee — it helps keep the project going! [![Ko-fi](https://img.shields.io/badge/Buy%20me%20a%20coffee-ko--fi-FF5E5B?logo=ko-fi&logoColor=white)](https://ko-fi.com/marcinkusnierz)

---

## Requirements

- macOS 13 Ventura or later
- DaVinci Resolve (any recent version)
- A Mac with a trackpad (built-in or Magic Trackpad)

---

## Installation

1. Download the latest `ResolveZoom.zip` from the [Releases](../../releases) page
2. Unzip and drag `ResolveZoom.app` to your Applications folder
3. Launch the app

**First launch:** macOS will block the app because it's not signed with an Apple Developer certificate. To open it:
- Right-click (or Control-click) `ResolveZoom.app` → **Open** → **Open**

You only need to do this once. After that, the app opens normally.

**Accessibility permission:** ResolveZoom needs Accessibility access to intercept trackpad gestures. A setup window will appear on first launch guiding you through the process.

---

## Usage

Once running, ResolveZoom appears as an icon in the menu bar. Open DaVinci Resolve, place it in focus, and start pinching on your trackpad — the timeline will zoom in and out.

**Menu bar status:**
- 🟢 **DaVinci Resolve active** — gestures are being intercepted
- ⚪ **Waiting for Resolve…** — Resolve is not in focus
- 🔴 **No accessibility permission** — grant access in System Settings

**Preferences** (click the menu bar icon → Preferences…):
- **Zoom Sensitivity** — controls how fast the timeline zooms. Default is 800; increase for faster zoom, decrease for finer control
- **Invert zoom direction** — reverses the zoom direction if it feels unnatural
- **Launch at Login** — toggle autostart with macOS

---

## Known Issues

### "Zoom Around Mouse Pointer" is not supported

DaVinci Resolve has an option under **View → Zoom Around Mouse Pointer** that, when enabled, makes the timeline zoom towards the cursor position instead of the playhead.

**ResolveZoom does not support this setting — the timeline will always zoom towards the playhead**, regardless of whether the option is enabled in Resolve.

**Why:** ResolveZoom works by intercepting trackpad pinch gestures and converting them into synthetic Alt+Scroll events that Resolve understands as zoom commands. Resolve's "Zoom Around Mouse Pointer" feature works correctly with native hardware scroll events, but our synthetic events take a different internal code path in Resolve that always defaults to playhead-centered zoom.

Several approaches were investigated to work around this limitation:
- Marking synthetic events as "continuous" (trackpad-style) using private CGEvent fields
- Sending gesture phase information alongside the scroll event
- Injecting synthetic magnify events (type 29) directly — Resolve ignores these entirely
- Querying the DaVinci Resolve scripting API — it does not expose timeline viewport zoom control

This remains an open problem. Contributions and ideas are welcome.

---

## License

MIT License — free to use, modify, and distribute.
