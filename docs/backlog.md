# Backlog

Features the owner has asked for that are not part of any segment yet. Each one needs the owner's go-ahead before work starts, and becomes a segment of its own with a plan and a decision record. Add new ideas at the end, with the date they were noted.

## Open a cleanup in Activity for its details

Noted: 2026-11-14 · Priority: not urgent

Each entry in Activity should open to further details about what was done, perhaps with an Apple Intelligence summary made on the device.

What exists today: each file is already a row of its own in Activity, with its identifier, so a detail view can open from a selected row without changing the list (decision record 0007).

## Undo more than the last cleanup with repeated ⌘Z

Noted: 2026-11-15 · Priority: not urgent

Pressing ⌘Z (Edit > Undo) once undoes the most recent cleanup. Pressing it again should undo the cleanup before that, and so on further back, one cleanup per press. The owner suggests keeping the actions on a stack with a maximum length, so the history cannot grow without limit.

What exists today:
- Edit > Undo only ever targets the newest cleanup run (`ActivityLog.latestCleanupRun`, used by `ContentView.undoCommands`). Once that run has been undone, ⌘Z is greyed out, even though older runs can still be undone one by one from Activity.
- The activity log already keeps every run, with what is needed to undo each change. It is on disk, so it survives a relaunch, and runs older than 90 days are pruned. The "stack" may therefore be the log itself, walked back from the newest run that still has something to undo, with the maximum length as a limit on how far back ⌘Z reaches.

To decide before building it:
- **The maximum length:** how many cleanups ⌘Z can reach back.
- **Older runs that can't be undone:** what happens when a run cannot be undone, for example because the Trash was emptied. Does ⌘Z skip it or stop there?
- **Across relaunches:** whether the history should carry over after the app is quit and reopened.
- **Redo:** whether ⇧⌘Z should redo what was undone.
