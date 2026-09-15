# Tempo

A tiny native macOS menu bar app that shows how far you are through your work
day, week, month, and year — in a glassy, customizable drop-down panel.

Default work schedule: **Mon–Fri, 10:00 → 18:00**. The day hits 0% at 10:00 and
100% at 18:00; the week runs Monday 10:00 → Friday 18:00 (work hours only).
Month and year can each count either work hours or plain calendar time.

## Build & run

```sh
./build.sh
open dist/Tempo.app
```

Look for the `W 43%`-style item in your menu bar and click it.

To keep it around permanently:

```sh
cp -R dist/Tempo.app /Applications/
open /Applications/Tempo.app
```

Then turn on **Launch at login** in the panel's settings (gear icon).

## Customize (gear icon in the panel)

- Work start/end times and which days count as workdays — plus **per-day
  hours** (e.g. Friday 10:00–17:00), which day/week/month/year math all honor
- Show/hide each row (Today / Week / Month / Year) and pick its style:
  **percent, bar, ring, or dot grid**
- **Counting basis per period**, with inheritance:
  - Week: work hours (from the daily schedule) or calendar
  - Month: *like week*, work hours, or calendar
  - Year: *like month*, *like week*, work hours, or calendar
  - "Like X" follows whatever that period is set to; a caption in settings
    shows what each period resolves to right now
- Menu bar item: live percentage text, plain icon, or a tiny filling ring —
  and which metric it tracks
- Accent theme: Aurora, Sunset, Ocean, Mono

Everything saves automatically and survives restarts.

## Development

```sh
swift build                     # debug build
.build/debug/Tempo --check      # run the progress-math self-checks
swift run Tempo                 # run the app directly (no bundle)
```

Self-checks live in `Sources/Tempo/Checks.swift` (Command Line Tools ship no
XCTest, so tests are a `--check` flag on the binary). To quit the app, click
the menu bar item and press the power button in the panel footer.
