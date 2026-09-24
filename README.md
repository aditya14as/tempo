<p align="center"><img src="Assets/icon-256.png" width="96" alt="Tempo logo"></p>

<h1 align="center">Tempo</h1>

<p align="center">
  A tiny native macOS menu bar app that shows how far you are through your
  work day, week, month, and year — in a glassy, customizable drop-down panel.
  It also keeps your Mac awake (like Amphetamine), switches windows with
  ⌥⇥ (like AltTab), remembers everything you copy (like Maccy), and holds
  files on a floating shelf (like Dropzone), so one app replaces four.
</p>

---

Tempo sits in your menu bar as a live figure like `T 87% · W 37%`: how far
you are through **T**oday and the **W**eek. Click it for the full panel, with
**Now / Tasks / Week / Awake / Clips** tabs, a scrolling task list, a
floating **Shelf** for parking files and links between apps, and a searchable
clipboard history.

Default schedule: **Mon–Fri, 10:00–18:00**. The day runs 0% at 10:00 to 100%
at 18:00; the week runs Monday 10:00 to Friday 18:00, counting work hours only.
Month and year can each count work hours or plain calendar time. Everything is
configurable, saves automatically, and survives restarts.

## Benchmark

Tempo next to the apps it replaces, each freshly launched and left alone
for 30 seconds (Apple M4, macOS 27, September 2026). Memory is the physical
footprint, the figure Activity Monitor's Memory column shows.

| App | Does | Memory | Idle CPU | App size |
|---|---|---:|---:|---:|
| **Tempo 1.0** | all of the below | **24 MB** | ~0.1% | **3.2 MB** |
| AltTab 11.6 | window switcher | 42 MB | 0.02% | 13 MB |
| Maccy 2.5 | clipboard history | 79 MB | 0.00% | 8.1 MB |
| Amphetamine 5.3 | keep awake | 33 MB | 0.00% | 7.6 MB |
| Dropzone 4.80 | file shelf | 65 MB | 0.00% | 73 MB |
| *The four together* | | *219 MB* | | *102 MB* |

After a working session (the ⌥⇥ switcher, the panel's tabs and the
clipboard popup all used) Tempo settles around 50 MB: it keeps the switcher's
window previews and its popups ready so they open instantly. Re-run it
yourself with `./Tools/benchmark.sh`.

## Install

macOS 14+. Tempo builds from source with the free Apple Command Line Tools
(no Xcode needed). Pick either way:

**Homebrew**

```sh
brew install aditya14as/tempo/tempo
cp -R "$(brew --prefix tempo)/Tempo.app" /Applications/ && open /Applications/Tempo.app
```

Homebrew can't write to `/Applications` itself, hence the second line. To
update: `brew reinstall aditya14as/tempo/tempo`, then run the second line
again. (The formula lives in
[aditya14as/homebrew-tempo](https://github.com/aditya14as/homebrew-tempo).)

**One line**

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

Five tabs across the top:

- **Now** — today, this week, this month, and this year, each shown as a
  percentage, bar, ring, or dot grid.
- **Tasks** — your to-do list, grouped by when things are due.
- **Week** — this week and next at a glance, with each task dotted on its due
  day (**+n** when a day has more than three) and a scrolling agenda
  underneath.
- **Awake** — keep your Mac from sleeping. See below.
- **Clips** — the latest things you copied: click one to copy it again, search
  them, pin or delete from the right-click menu, pause recording or skip the
  next copy, and open the full history popup. See
  [Clipboard history](#clipboard-history).

A tab only shows while its feature is on (see **Features** below). The **gear**
opens settings; the **power button** quits Tempo.

### Tasks and due dates

- Type in the quick-add field at the top and press Return. Dates in the text
  become the due time (`call Sam tomorrow 3pm`, `fri 9:30`, `in 2 hours`), and
  a leading or trailing `!` flags the task. Flagged tasks sort first.
- There's no cap; the list scrolls. Open tasks are grouped **Overdue / Today /
  Upcoming / No date** (turn grouping off in Settings → Tasks).
- Check a task off and it moves, after a second, to a collapsible
  **Completed** section with a **Clear** button. Completed tasks clear
  themselves after a week by default (a day, a month, or never in Settings).
- Long titles wrap, and a task can carry an optional notes line.
- Hover a task for **flag**, **due**, and **delete** buttons, or right-click it
  for a menu. Drag rows to reorder. Deleted by mistake? Hit
  **Undo**.
- Drop files or links on the list to turn them into tasks, with an attachment
  chip.
- Click the **clock** button on a task to set a due date and time: one-tap
  presets (In 2h, Tonight, Tomorrow, Next Mon), a full calendar, and a time
  stepper.
- Tempo sends a notification when a task is due, and the chip turns **red**
  once it's overdue.
- From the clock popover you can also **Add to Apple Reminders** (it asks for
  Reminders access the first time). Exporting the same task again updates its
  reminder instead of adding a duplicate.

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

### Keep awake

The **Awake** tab keeps your Mac from sleeping, the way Amphetamine does.

- **One tap to start.** Pick 30m, 1h, 2h, or 4h, **Until 6:00 PM** (today's
  work end, from your schedule), **Forever**, or **Custom**. Custom starts a
  session for any length, until any date and time (a calendar plus a time
  picker), or while an app stays open.
- **While it runs,** a ring counts down the time left, **+15m** and **+1h** add
  time, and **Stop** ends it. A bolt appears in the menu bar, with the time left.
- **Options:**
  - keep the screen on or let it sleep, and allow the screen saver after a few
    idle minutes
  - **move the pointer when idle**, a one-pixel nudge after 1–60 idle minutes so
    Slack, Teams, and Zoom don't mark you away (needs Accessibility, like the
    switcher; it never wakes a sleeping screen or the lock screen)
  - **stay awake with the lid closed**, on a MacBook with no external display
    (see below)
  - **keep external drives spinning**, by touching a hidden file on them every
    minute (all external drives, or the ones you pick)
  - stop on low battery or when unplugged, and get a notification when a
    session ends
- **Automatic:** stay awake by itself during work hours, with an external
  display connected, while plugged in, while chosen apps are open, on chosen
  **Wi-Fi networks**, or while chosen **USB devices** are plugged in. macOS
  only shows Wi-Fi network names to apps with Location access, so the Wi-Fi
  rule asks for it once. Tempo never reads your location.
- **Settings** add a global shortcut to start or stop, the length of the
  **Keep awake** button, a warning before a session ends, and start-at-launch.

A session survives quitting and relaunching Tempo.

**Closed-lid mode.** macOS sleeps a closed MacBook no matter what an app asks,
unless sleep is switched off system-wide (`pmset disablesleep`), which needs
an administrator. The first time you turn it on, Tempo asks for your password
once and adds a sudo rule (`/etc/sudoers.d/tempo-closed-lid`) that allows only
`pmset -a disablesleep 1` and `pmset -a disablesleep 0`. After that, Tempo
switches sleep off when a session starts and back on when it ends. If Tempo
quits or crashes, a small watchdog turns sleep back on. **Settings → Awake →
Remove…** deletes the rule. A closed Mac that stays awake can get hot, so keep
it out of a bag.

### Window switcher

Hold **⌥** and press **⇥** to see every open window as a live preview, then
let go of ⌥ to jump to the one you picked. A quick ⌥⇥ flips between your last
two windows without showing anything.

While the switcher is open:

| Key | Does |
|---|---|
| ⇥ or → | next window |
| ⇧ or ← | previous window |
| ↑ ↓ | move between rows |
| ↩ or click | open the selected window |
| W / M / H / Q | close window / minimize / hide app / quit app |
| ⎋ | cancel |

**⌥\`** cycles only the current app's windows. Hovering a card selects it, and
the pointer follows you to the window you open. Windows on other Spaces show
their Space number, and minimized and hidden ones sit at the end.

**First time:** the **Now** tab shows a one-step setup card. Click **Allow
Accessibility**: System Settings opens at the right page, and a small guide
beside it says what to click (and has a Tempo icon to drag into the list if
Tempo isn't there). The guide closes by itself once you flip the switch, and
the switcher works right away. Live previews are optional: the card offers
**Screen Recording** next, or **Use app icons** to skip it.

If you used AltTab or Amphetamine before, quit them so they don't fight
Tempo for ⌥⇥ or the power settings. Settings → **Switcher** changes the hold
key (⌥, ⌃, or ⌘), the style (previews, icons, or a list), the card size, which
Spaces and screens it uses, and apps to never show.

### Clipboard history

Tempo remembers what you copy: text, links, colours, rich text, images and
files. Press **⇧⌘C** anywhere (change it in Settings) to open the history at
the pointer, type to filter it, and press **↩** to paste the pick into the
app you were in. It opens over full-screen apps too. The **Clips** tab in the
panel lists the latest ones.

The popup works like Maccy's:

- **The list** on the left: text entries as one line, images as real
  thumbnails, each with the app it came from and its shortcut (⌘1–⌘9, or
  ⌘+letter when pinned). Pinned entries sit on top, above a thin divider.
- **The preview** on the right: the full text, the image, the files, or a
  colour swatch, then details — app, dimensions or length, size, first and
  last copy time, how many times you copied it, and its pin. The button at
  the end of the search bar hides or shows it.
- **Buttons** over the preview: copy the text in an image, pin or unpin, and
  delete.
- **The footer**: Clear all, Pause recording, and Settings.

**Text in images is read automatically**, so searching finds screenshots by
the words in them, and the preview offers **Copy text**.

While the popup is open:

| Key | Does |
|---|---|
| type | filter (exact, fuzzy, or regex; set in Settings) |
| ↑ ↓ | move the selection |
| ↩ or click | paste (or only copy, if you turn pasting off) |
| ⌥↩ or ⌥-click | the other one: copy instead of paste, or the reverse |
| ⇧ with any of those | flip "paste as plain text" |
| ⌘1 – ⌘9 | pick one of the first nine entries |
| ⌥P | pin or unpin (pinned entries stay on top and get a ⌘-letter) |
| ⌥⌫ / ⌥⌘⌫ | delete the entry / clear everything that isn't pinned |
| ⌥T | copy the text in an image |
| ⌘, | open Tempo's settings |
| ⎋ | clear the search, then close |

Pasting needs **Accessibility**, the same switch the window switcher uses.
Without it, picking an entry just copies it and you press ⌘V yourself.
Copies from password managers (1Password, Bitwarden, Keychain Access,
Passwords) and anything an app marks as concealed or temporary are never
recorded. Tempo keeps the latest **150** entries (pinned ones don't count and
never fall off). Settings → **Clipboard** changes the shortcut, how many entries
to keep (10–2000), search mode, order, where the popup opens, which kinds to
save, and which apps or text patterns to skip, and can pause recording. The
history is kept only on your Mac, readable only by you, in
`~/Library/Application Support/Tempo/Clipboard`.

**Coming from Maccy?** Settings → Clipboard → **Import from Maccy** brings
your existing history over, pins included (macOS asks once to let Tempo read
Maccy's data). Then quit Maccy (there's a button for that too), since it
also listens for ⇧⌘C.

## Customize

Open settings with the **gear** icon in the panel.

- **Features** — switch each part of Tempo on or off: **Work hours** (progress
  and the menu bar percentages), **Tasks** (the Tasks and Week tabs and their
  reminders), **Keep awake**, **Window switcher**, **Shelf**, and
  **Clipboard history**. Turning one
  off hides its tab, settings, and menu bar pieces and stops it running. With
  work hours off, the menu bar shows a plain icon (or just the bolt while
  awake).

- **Permissions** — only what the features you use need, each with its
  reason and an **Allow** button. Tempo asks for nothing at launch:
  Accessibility for the switcher and the pointer nudge, Screen Recording
  (optional) for previews, Notifications once a task has a due time or an
  Awake session can alert you, and Location or Reminders only the first time
  you use a Wi-Fi rule or Apple Reminders.

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
- **Appearance** — System, Light, or Dark for all of Tempo's windows, and a
  **Glass ↔ Solid** slider: more solid reads better over busy windows behind
  the panel, the switcher, and the clipboard popup.
- **Switcher**, **Awake**, and **Clipboard** — see the sections above.

Everything saves automatically and survives restarts.

## Development

```sh
swift build                     # debug build
.build/debug/Tempo --check      # run the self-checks
swift run Tempo                 # run the app directly (no bundle)
```

Self-checks live in `Sources/Tempo/Checks.swift`. The Command Line Tools ship no
XCTest, so tests are a `--check` flag on the binary; it covers the progress math,
the Shelf's drop-card placement, keep-awake planning, the switcher's
ordering, navigation, and layout, and clipboard search, sorting, and dedupe. `build.sh` signs with a "Tempo Local Signing"
certificate from your login keychain when one exists (override with
`TEMPO_SIGN_IDENTITY`), so Accessibility and Screen Recording survive rebuilds.
Without it the build is signed ad-hoc: after a hand rebuild run
`tccutil reset Accessibility com.ivy.tempo` and allow Tempo again
(`install.sh` does this for you). To quit the app, click the menu bar item
and press the power button in the panel footer.

Write `@ViewState` wherever you'd normally write `@State`. The macOS 27 SDK
turns `@State` into a compiler macro whose plugin ships only with Xcode, so
plain `@State` no longer builds with the Command Line Tools;
`Sources/Tempo/ViewState.swift` is a thin wrapper over SwiftUI's `State` that
does.
