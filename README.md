# Daily and weekly checklist widgets

Two small panels on the Mac desktop showing today's and this week's to-do lists from an
Obsidian vault. You can tick, edit, add and delete tasks right on them, and every change is
written straight into the note.

There's no AI, account, internet connection or subscription involved. Your lists are plain
Markdown files, so they stay readable with or without this program, and with or without Obsidian.

## Put it on a Mac

1. Install Apple's free compiler, if you haven't: `xcode-select --install`
2. Get this folder: `git clone https://github.com/Flottohs/obsidian-checklist-widget.git`
3. Put your folders in `worklist-location.txt` (daily) and `weekly-location.txt` (weekly):
   ```
   location: ~/Documents/alevelsvault/09 Planning/Worklist
   ```
4. Run `./build.sh`
5. If macOS asks to let `checklist-widget` use your Documents folder, click Allow.

They now start at every login and restart themselves if they crash.
To remove them, run `./uninstall.sh`. Your notes aren't touched.

## How it behaves

| | Daily | Weekly |
|---|---|---|
| Notes are named after | the day they're for | the Monday of their week |
| A new note appears | at 8pm, for tomorrow | Monday 00:00 (end of Sunday night) |
| New notes come from | `Daily template.md` | `Weekly template.md` |
| Position | right edge, middle of the screen | just left of the daily one |

- **Which note shows:** the newest note in the folder named `YYYY-MM-DD.md`. If you make a newer
  one by hand, it takes over. Other notes in the folder are ignored.
- **Templates:** found in the templates folder set in Obsidian (or a top-level folder with
  "template" in its name). The name only has to contain "daily" or "weekly". `## Headings` become
  sections on the widget. If you change a template, the note being shown changes to match and keeps
  its tasks, ticks and any text you wrote. Older notes are never changed.
- **Carry-over:** when a new note appears, unticked tasks from the note before it are added, in the
  section with the same name. A task is skipped if it's already on the new note, ticked or not,
  ignoring capitals and spacing. If the Mac was off for days, it carries from the newest note there is.
- **Carry-over happens once per note.** The note gets the line `carryover: done` in its frontmatter
  (the Properties block at the top), so a task you delete stays deleted. Remove that line to make it
  carry over into that note again.
- **The 8pm cut-off:** the daily list carries over at 8pm. If you then tick something on the old note
  in Obsidian, the copy on tomorrow's list stays. Tick or delete it there.

## Changing things

| To change | Do this |
|---|---|
| Sections or repeating tasks | Edit the template in Obsidian. No rebuild needed. |
| Which folder is used | Edit the `location:` line. No rebuild needed. |
| The 8pm time, widget width, margins | `Config` at the top of `Core.swift`, then `./build.sh` |
| Which side the weekly one sits on | `slot` in `Mode` and `place()` in `ChecklistWidget.swift`, then `./build.sh` |

Run `./build.sh` again if you move this folder. It runs the tests first and won't install if any fail.

## If something's wrong

Each widget writes what it's doing to a log:

```
tail -20 ~/Library/Logs/checklist-widget.log    # daily
tail -20 ~/Library/Logs/weekly-widget.log       # weekly
```

| Symptom | What to do |
|---|---|
| A widget is missing | Run `./build.sh`. Also check it isn't hidden behind a window. |
| "Folder not found" on the widget | Fix the `location:` line. It recovers within seconds. |
| A plain list with no sections | The template wasn't found. Check its name has "daily" or "weekly" in it. The log says so too. |
| "Operation not permitted" in the log | System Settings > Privacy & Security > Files and Folders: allow `checklist-widget`. |
| "Resource deadlock avoided" in the log | iCloud offloaded a file. The widget should download it itself, so check you're online. |
| "Unable to get updated LWCR" in the system log | launchd rejected a rebuilt program. `./build.sh` re-registers it, which fixes this. |
| `./build.sh` says tests failed | It printed which ones, and the running widgets are untouched. See the next section. |
| `./build.sh` can't compile after a macOS or Xcode update | Apple has probably changed something. Read the error: it names the file and line. All the window code is in `ChecklistWidget.swift`. The older working version is in `git log`. |

Worst case, your lists are ordinary notes: open them in Obsidian or any text editor.

## How the code is laid out

| File | What's in it |
|---|---|
| `Core.swift` | Everything except the window: dates, Markdown, template merge, carry-over, finding folders, reading and writing notes (`NoteStore`) |
| `ChecklistWidget.swift` | The window and what's drawn in it (SwiftUI and AppKit) |
| `Tests/main.swift` | Tests for `Core.swift`, using a temporary vault and a fake clock. They never touch your notes. |
| `test.sh` | Runs the tests |
| `build.sh` | Runs the tests, compiles, writes the LaunchAgent files and starts both widgets |
| `uninstall.sh` | Removes the widgets from the Mac |
| `*-location.txt` | Which folder each widget uses |
| `BuildPaths.swift` | Written by `build.sh` on each build; not in git |

It's one program. `checklist-widget` runs as the daily widget, and `checklist-widget --weekly` as the
weekly one. Every 1.5 seconds, `NoteStore.refresh()` works out which note should be showing, creates
it if needed, applies template changes and carry-over, and reloads the note if the file changed.
That's why edits made in Obsidian appear on their own.

To change the logic safely: edit `Core.swift`, add a check to `Tests/main.swift` for what you
changed, and run `./test.sh`. Nothing is installed until you run `./build.sh`.
