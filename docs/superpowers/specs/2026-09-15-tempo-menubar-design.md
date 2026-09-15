# Tempo — Work-Time Progress Menu Bar App

**Date:** 2026-09-15 · **Status:** Approved by user (chat)

## What it is

A native macOS menu bar app (Swift + SwiftUI, built with SPM, no Xcode project) that
shows how far you are through your work day, week, month, and year — with a modern,
glassy, customizable drop-down panel.

## Core time model

- Work day: 10:00 → 18:00 (customizable start/end).
- Workdays: Mon–Fri (customizable per-day toggles).
- **Day progress:** 10:00 = 0%, 18:00 = 100%. Clamped outside the window. Non-workday = "Day off".
- **Week progress:** work seconds elapsed since Monday 10:00 ÷ total work seconds in the
  week (default 40h). Weekend = 100%.
- **Month / Year progress:** each independently toggleable between:
  - *Work-hours mode* — completed work seconds ÷ total work seconds in the period.
  - *Calendar mode* — plain elapsed time ÷ total period length.

## UI

**Menu bar item** — style is user-selectable:
1. Live text, e.g. `W 43%`
2. Plain icon
3. Tiny filling ring (template NSImage, adapts to dark/light)

Plus a picker for *which* metric it shows (today / week / month / year).

**Panel** (MenuBarExtra `.window` style, ~320pt wide):
- Header: full date + subtitle.
- One row per metric (Today, Week, Month, Year), each individually:
  - show/hide toggle
  - display style: **percent / bar / ring / dot-grid**
- Each row shows a context subtitle: "3h 20m left", "Starts in 40m", "Day off",
  "12 workdays left", "Weekend", etc.
- Footer: gear (opens in-panel settings) and quit button.
- Updates every second while open; menu bar label updates every 30s.

**Settings** (in-panel, replaces the rows view):
- Start/end time pickers, workday chips (M T W T F S S).
- Per-row visibility + style.
- Month/year mode pickers.
- Menu bar style + metric.
- Theme picker (gradient accent presets: Aurora, Sunset, Ocean, Mono).
- Launch at login (SMAppService; only effective when running from the .app bundle).
- All settings persist to UserDefaults as JSON (`AppConfig` Codable).

## Architecture

- `ProgressEngine` — pure static functions (date math only, no UI, unit-tested).
- `Models` — `AppConfig`, `WorkSchedule`, enums for styles/modes/themes.
- `ConfigStore` — ObservableObject wrapping `AppConfig`, saves on change.
- `Ticker` — 30s timer driving the menu bar label.
- Views: `PanelView`, `MetricRowView` + style components, `SettingsView`, `MenuBarLabel`.
- `build.sh` — `swift build -c release`, assembles `dist/Tempo.app`
  (Info.plist with `LSUIElement=true`), ad-hoc codesign.

## Error handling / edge cases

- Corrupt or missing saved config → fall back to defaults.
- `endMinute <= startMinute` prevented in UI; engine guards against divide-by-zero.
- Empty workday set → period progress reports 0 (guarded).
- Launch-at-login registration failure is silent (bare binary runs fine without it).

## Testing

`swift test` — unit tests on `ProgressEngine`: day midpoint/clamps, day-off nil,
week midpoint, week total = 40h, calendar-mode fraction, weekend = 100%.
