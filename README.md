# TimerBar

A native macOS menu bar countdown-timer app (AppKit/Swift).

## Build & run

```bash
./build.sh
open build/TimerBar.app
```

The app lives only in the menu bar (no Dock icon). Look for the ⏱ icon in the
top-right of the menu bar.

## Features

- **Menu bar item** — shows a `timer` icon when idle, or each active timer as a
  colored dot ● + monospaced countdown (`MM:SS`, or `H:MM:SS` past an hour).
- **Click the icon** to open the dropdown (an `NSPopover`, not a menu — so the
  inline form's text fields accept typing):
  - **➕ Create Timer** button. Clicking it expands the setup form right inside the
    dropdown (no separate modal window):
    - Toggle between **Duration** (hours + minutes) and **At a time** (analog clock
      picker for a specific time of day — rolls to tomorrow if already passed).
    - **Label** (optional) text field and a row of **color** swatches.
    - **Create** / **Cancel**.
  - **Timers** list: each active timer shows its color dot, label, remaining time,
    and inline **Pause/Resume**, **Restart**, and **Delete** buttons.
  - A **Launch at login** checkbox and a **Quit** button in the footer.
  - Label, color, and live countdown appear in both the menu bar and the dropdown.
- When a timer hits zero it beeps, shows an alert, and is marked "done" until you
  delete or restart it.

## Notes

- The build is unsigned. On first launch macOS Gatekeeper may block it — right-click
  the app → **Open**, or run:
  `xattr -dr com.apple.quarantine build/TimerBar.app`
- Requires macOS 11+ and the Xcode command line tools (`swiftc`).
