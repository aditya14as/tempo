# Tempo — Awake (keep-awake) and Switcher (⌥⇥ window switcher)

**Date:** 2026-09-22 · **Status:** Implemented

## Why

The user runs two extra menu bar utilities all day: **Amphetamine** (keep the
Mac awake) and **AltTab** (Windows-style ⌥⇥ window switcher with previews).
Tempo already owns a menu bar slot, a glassy panel, a schedule, and a
notification pipeline. Folding both jobs into Tempo means one app, one icon,
and a couple of features neither original can offer (keep awake *until the end
of the workday*, keep awake *during work hours*).

Design goals, in order: it must work every time; it must feel native to Tempo
(rounded type, gradient accent, 14pt-radius cards, `.ultraThinMaterial`); it
must need as little permission ceremony as possible and explain the rest.

## Awake

### Model

`AwakeConfig` (settings) + `AwakeSession` (the running session, persisted so a
relaunch resumes it) + `AwakeTriggers` (auto-sessions). Sessions have one of
three kinds: **indefinite**, **until(Date)** (timed presets, "until 18:00",
custom time all resolve to a date), **whileApp(AppRef)**.

Engine = `AwakeEngine` (`@MainActor`, `ObservableObject`, singleton). It owns
exactly one IOKit power assertion at a time:

| Setting | Assertion |
|---|---|
| Keep display on (default) | `PreventUserIdleDisplaySleep` |
| Allow display sleep | `PreventUserIdleSystemSleep` |

When the display is kept on and "allow screen saver" is off, the engine also
declares user activity every 30 s (`IOPMAssertionDeclareUserActivity`), which is
what actually holds the screen saver off. A 1 s tick drives the countdown, the
low-battery guard, the "ends in N min" warning and the end-of-session
notification. A trigger session is a manual-less session the engine starts
when any enabled trigger is true (external display attached, on power, during
scheduled work hours, a listed app running) and ends when none are. A manual
session always wins over a trigger session; ending a manual session while a
trigger holds falls back to the trigger session, not to sleep.

### UI

Fourth panel tab **Awake**:

1. **Status card** — ring (theme gradient) showing time left for timed
   sessions, ∞ for indefinite, app icon for while-app; title + subtitle
   ("Until 18:00 · screen stays on", "While Xcode is open", "Mac can sleep
   normally"). Big primary button: **Keep awake** / **Stop**.
2. **Quick start chips** — `30m 1h 2h 4h · Until 18:00 · ∞`. "Until 18:00"
   is today's work end from the schedule (hidden on days off / after hours).
   Tapping a chip starts (or restarts) a session immediately. A **Custom…**
   chip opens a popover with an "until" time picker and a "for" stepper.
3. **While an app is open** — a menu listing running regular apps with icons.
4. **Options** — Allow display sleep · Allow screen saver · Stop below N%
   battery · Notify when it ends · Warn N min before.
5. **Auto (triggers)** — toggles: external display · on power · work hours ·
   apps (multi-select); a master "Pause auto" switch.

Menu bar: while awake, a small bolt glyph is drawn to the left of the T/W
badges (template image, so it tracks light/dark), optionally followed by the
time left (`⚡ 42m`). Settings → Awake holds the shortcut recorder (Carbon
`RegisterEventHotKey`, no permission needed), start-at-launch, sounds, and the
default duration used by the shortcut.

## Switcher

### Interaction (matches AltTab's defaults)

Hold **⌥**, press **⇥** → the switcher appears instantly, listing windows
most-recently-used first with the *previous* window pre-selected. While held:
⇥ / → next, ⇧⇥ / ← previous, ↑↓ move by row, mouse hover selects, click
focuses. Release ⌥ → focus the selection. ⎋ cancels. Letters while open:
**Q** quit app, **W** close window, **M** minimize, **H** hide app. ⌥` cycles
just the active app's windows. Every event the switcher consumes is swallowed
before the front app sees it (CGEventTap at head of session, `.defaultTap`).

### Windows

`WindowScanner` enumerates via Accessibility: for every running app with a
regular activation policy, `kAXWindowsAttribute`, keeping standard/dialog
subroles with a non-empty title or a real size, mapped to a `CGWindowID`
through `_AXUIElementGetWindow` for bounds/space/preview lookups.
`CGWindowListCopyWindowInfo(.optionAll)` supplies z-order, on-screen state and
bounds. MRU order is tracked from `NSWorkspace` app-activation notifications
plus per-app AX observers for focused-window changes.

Focusing: un-minimize via AX if needed, unhide the app, `activate`, then
`AXRaise` + set main/focused. Windows on other Spaces switch Spaces as macOS
raises them. Optional cursor-follows-focus warps the pointer to the window.

Previews use ScreenCaptureKit (`SCScreenshotManager`) when Screen Recording is
granted; otherwise cards show the app icon at preview size. Both look
intentional — the icon fallback is a first-class style, not an error state.

### UI

Floating `NSPanel` (non-activating, `.popUpMenu` level, all Spaces,
full-screen auxiliary), `.ultraThinMaterial`, radius 22, centred on the screen
with the mouse (setting: active / main). Three styles:

- **Previews** — grid of cards (S/M/L: 180 / 232 / 300 pt wide, 16:10 box,
  image aspect-fit, rounded 10), app icon overlapping the bottom-left corner,
  one-line title beneath. Selected = 2.5 pt gradient ring + tinted fill.
  Columns fit within 85 % of the screen; more than three rows steps the size
  down, then scrolls.
- **Icons** — row of 64 pt icons (wrapping), selected window's title below.
- **List** — rows of icon · title · app name, for people with 30+ windows.

Badges: minimized (↓ chip), hidden (eye.slash), other Space (space number when
the private Space APIs link). Optional key-hint strip at the bottom.

### Permissions

Accessibility is required (event tap + window control). Screen Recording is
optional (previews). Tempo is ad-hoc signed, so every rebuild changes its code
hash and macOS silently stops honouring earlier grants; `install.sh` therefore
runs `tccutil reset` for both services before installing, and the app shows a
"Grant Accessibility" card on the Now tab until it is trusted.

## Architecture (new files)

| File | Owns |
|---|---|
| `FeatureModels.swift` | `AppRef`, `KeyCombo`, `AwakeConfig`, `AwakeSession`, `AwakeTriggers`, `SwitcherConfig` + enums |
| `Awake.swift` | `AwakeEngine`, `AwakePlanner` (pure: end dates, labels, trigger evaluation), power/battery/display/app watchers |
| `AwakeView.swift` | Awake tab, custom popover, settings section |
| `Hotkeys.swift` | `HotkeyCenter` (Carbon), `ShortcutRecorder` view |
| `Switcher/WindowScanner.swift` | `SwitchWindow`, AX + CG enumeration, MRU, focus/close/minimize/hide/quit |
| `Switcher/SwitcherController.swift` | Event tap, state machine, selection |
| `Switcher/SwitcherPanel.swift` | Panel + SwiftUI views for the three styles, layout math (pure) |
| `Switcher/Previews.swift` | ScreenCaptureKit capture + cache |
| `Permissions.swift` | AX / Screen Recording status, prompts, System Settings deep links |

Self-checks (`Tempo --check`) cover the pure parts: config round-trips,
`AwakePlanner`, `KeyCombo`, window filtering/ordering, and layout math.
