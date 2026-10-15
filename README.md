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
- **Built-in diagnostics** — the menu shows which app is detected, how many gestures were handled, and why the last one was skipped
- **Manual Resolve selection** — point the app at your Resolve install if auto-detection doesn't find it
- **Fusion-aware pinch handling** — automatically passes pinch gestures through when Fusion is active, where Resolve provides native zoom
- **Zoom around the mouse pointer** — honours Resolve's View → Zoom Around Mouse Pointer setting

If ResolveZoom saves you time, consider buying me a coffee — it helps keep the project going! [![Ko-fi](https://img.shields.io/badge/Buy%20me%20a%20coffee-ko--fi-FF5E5B?logo=ko-fi&logoColor=white)](https://ko-fi.com/marcinkusnierz)

---

## Requirements

- macOS 13 Ventura or later
- DaVinci Resolve (any recent version)
- A Mac with a trackpad (built-in or Magic Trackpad)

**Tested on:** macOS 26 Tahoe with DaVinci Resolve 21.0.4. Earlier versions were tested on macOS 15 Sequoia.
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

ResolveZoom checks Resolve's active page once per second while Resolve is focused. The Accessibility scan runs on a background utility queue with a 50 ms IPC timeout, so an unresponsive Resolve UI cannot interrupt pinch handling.

---

## Zoom Around Mouse Pointer

DaVinci Resolve has an option under **View → Zoom Around Mouse Pointer** that makes the timeline zoom towards the cursor position instead of the playhead. ResolveZoom supports it: enable the option in Resolve and pinches zoom around the pointer. With the option off, they zoom towards the playhead as before.

**How it works:** Resolve only anchors the zoom on the pointer when Option is actually held in the system keyboard state. A scroll event that merely carries the Option flag still zooms, but around the playhead — which is why marking the events continuous, adding gesture phases or injecting magnify events never helped. So for the duration of a pinch ResolveZoom holds a synthetic Option key, and releases it as soon as the gesture ends. As a safety net it is also released after 150 ms without pinch events, when a pinch event arrives while a mouse button is held, when another app comes forward, and when ResolveZoom quits. If you are already holding Option yourself, ResolveZoom leaves it alone.

---

## Known Issues

### Option can stay held after a force-quit mid-pinch

If ResolveZoom is force-quit or crashes while a pinch is in progress, it never gets to release its synthetic Option key, and clicks will act as Option-clicks. Press and release Option once to clear it.

---

## License

MIT License — free to use, modify, and distribute.
