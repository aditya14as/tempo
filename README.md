<p align="center"><img src="Assets/icon-256.png" width="96" alt="Tempo logo"></p>

<h1 align="center">Tempo</h1>

<p align="center">
  A tiny native macOS menu bar app that shows how far you are through your
  work day, week, month, and year — in a glassy, customizable drop-down panel.
</p>

---

Tempo sits in your menu bar as a live figure like `T 87% · W 37%`: how far
you are through **T**oday and the **W**eek. Click it for the full panel, with
**Now / Tasks / Week** tabs, a five-item task list, and a floating **Shelf**
for parking files and links between apps.

Default schedule: **Mon–Fri, 10:00–18:00**. The day runs 0% at 10:00 to 100%
at 18:00; the week runs Monday 10:00 to Friday 18:00, counting work hours only.
Month and year can each count work hours or plain calendar time. Everything is
configurable, saves automatically, and survives restarts.

## Install

One line, macOS 14+:

```sh
curl -fsSL https://raw.githubusercontent.com/aditya14as/tempo/main/install.sh | bash
```

It builds Tempo from source with the free Apple Command Line Tools (no Xcode
needed), copies it to `/Applications`, and launches it. If you don't have the
Command Line Tools yet, the script asks macOS to install them: click **Install**
in the dialog, then run the line again. Re-run it any time to update.

Prefer to do it by hand?

```sh
git clone https://github.com/aditya14as/tempo.git
cd tempo
./build.sh
cp -R dist/Tempo.app /Applications/
open /Applications/Tempo.app
```

The build is unsigned (ad-hoc), so if macOS complains on first launch,
right-click the app and choose **Open**. To try it without installing, skip the
`cp` line and just `open dist/Tempo.app`.

## Usage

Look for the `T 87% · W 37%`-style item in your menu bar and click it to open
the panel. Turn on **Launch at login** in settings (the gear icon) so Tempo
starts with your Mac.

### The panel

Three tabs across the top:

- **Now** — today, this week, this month, and this year, each shown as a
  percentage, bar, ring, or dot grid.
- **Tasks** — your top five focus items for the day.
- **Week** — this week and next at a glance, with each task dotted on its due
  day and an agenda list underneath.

The **gear** opens settings; the **power button** quits Tempo.

### Tasks and due dates

- Type a task and press Return. Keep up to five.
- Click the **clock** button on a task to set a due date and time: one-tap
  presets (In 2h, Tonight, Tomorrow, Next Mon), a full calendar, and a time
  stepper.
- Tempo sends a notification when a task is due, and the chip turns **red**
  once it's overdue.
- From the clock popover you can also **Add to Apple Reminders** (it asks for
  Reminders access the first time).

### The Shelf

The Shelf is a small floating window that works like a notch shelf: a place to
drop files and links while you carry them from one app to another. Open it from
the **tray icon** in the panel footer.

**To drop something in,** start dragging any file or link. The moment you do, a
drop card appears. Drag onto it and let go — you'll hear a soft *pop*. Where the
card shows up depends on where the drag starts:

- **From Finder, a browser, VS Code, or an Electron editor** (like Conductor),
  the card pops up near the top-center of the screen the instant you pick the
  file up. Drag onto it and release.
- **From Zed,** it works a little differently — see the steps just below.

**To take something back out,** drag any tile off the Shelf into Mail, Slack,
Finder, anywhere. The tiles are the real files and links, not copies. The Shelf
floats and stays open while you go find the other window.

#### Dropping from Zed, step by step

Zed keeps a drag inside its own window and only tells macOS about it once the
file **leaves** that window — so nothing can appear while you're still hovering
over the editor. With Zed filling the screen, the way out is the menu bar:

1. Start dragging the file from Zed's file tree.
2. Drag it **up into the menu bar** at the very top of the screen.
3. A drop card appears right under your pointer and follows it along the bar.
4. **Let go on the card.** You'll hear the *pop*, and the file lands on the Shelf.

macOS may flash **Mission Control** open while you linger at the top edge — that's
a system gesture, not Tempo. It doesn't matter: the card is pinned in place and
stays on top through it, so you can still release onto it. If Mission Control is
still showing after you drop, press **Escape** to dismiss it.

> **Tip:** the card sits directly under your cursor in the menu bar, so there's
> nothing to aim at. Just let go.

## Customize

Open settings with the **gear** icon in the panel.

- **Schedule** — work start and end times, which days count as workdays, and
  **per-day hours** (e.g. Friday 10:00–17:00). Day, week, month, and year math
  all honor these.
- **Day slots** — split a day into up to four blocks (e.g. 11:00–12:00 and
  14:00–15:00). Breaks between slots don't count toward progress.
- **Rows** — show or hide each of Today / Week / Month / Year, and pick its
  style: percent, bar, ring, or dot grid.
- **Counting basis per period,** with inheritance:
  - **Week** — work hours (from the daily schedule) or calendar.
  - **Month** — *like week*, work hours, or calendar.
  - **Year** — *like month*, *like week*, work hours, or calendar.
  - *"Like X"* follows whatever that period is set to; a caption shows what each
    period resolves to right now.
- **Menu bar item** — live percentage text, a plain icon, or a tiny filling
  ring, and which metric it tracks.
- **Accent theme** — Aurora, Sunset, Ocean, or Mono.

Everything saves automatically and survives restarts.

## Development

```sh
swift build                     # debug build
.build/debug/Tempo --check      # run the self-checks
swift run Tempo                 # run the app directly (no bundle)
```

Self-checks live in `Sources/Tempo/Checks.swift`. The Command Line Tools ship no
XCTest, so tests are a `--check` flag on the binary; it covers the progress math
and the Shelf's drop-card placement. To quit the app, click the menu bar item
and press the power button in the panel footer.

Write `@ViewState` wherever you'd normally write `@State`. The macOS 27 SDK
turns `@State` into a compiler macro whose plugin ships only with Xcode, so
plain `@State` no longer builds with the Command Line Tools;
`Sources/Tempo/ViewState.swift` is a thin wrapper over SwiftUI's `State` that
does.
