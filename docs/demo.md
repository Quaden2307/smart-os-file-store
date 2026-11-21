# Demo mode

A fake home folder and a one-command launch, for recording the demo video. Debug builds and scripts only; the release app gains nothing and loses nothing.

## Build, reset and launch

```bash
scripts/run-demo.sh            # builds the debug app and opens it on the demo home
scripts/run-demo.sh --reset    # the demo home and its activity log back as they started, then opens it
```

- The demo home is `$TMPDIR/SmartOSDemo/Home` (Downloads 60 items, Desktop 25, Documents 40), with a fake Applications folder beside it holding Sketchpad 3.2, NoteNest 1.8 and Tasker 2.0. `scripts/make-demo-home.sh [path]` builds it alone. It refuses your home, the folders in it, system places and any folder holding files it did not make, and deletes only a folder it marked (`.smartos-demo-home`).
- Large files are APFS clones of one 256 MB and one 8 MB file, so each reports its full size; the home takes about 500 MB of real disk (`du` counts the clones in full and says about 1.6 GB).
- The launch passes `-DemoHome`, `-ApplicationsFolder`, `-GracePeriodSeconds 0`, `-WindowSize 1440x900` (centred), `-SkipWelcome`, `-TurnOnStandardFolders` and `-SeedDemoHistory`.
- `-SeedDemoHistory` writes thirteen past cleanups over twelve weeks into the demo home's own activity log (through the log's recording calls, with past dates) when that log has no run yet, so Insights has a past. Those runs name fictional files: their Undo buttons find nothing to put back.
- The activity log is the debug build's own for this demo home (under `$TMPDIR/com.quaden2307.SmartOSFileStore.debug/`), never the real one. Settings changed while demoing still go to the app's normal preferences.
- A picture of the window without recording the screen: add `-SnapshotTo <name>` (and `-StartPlace downloads|desktop|documents|storage|activity`); the app prints the window as base64 PNG on standard output (`grep '^SNAPSHOT'`, then `base64 -D`). It is drawn off screen, without the toolbar.

## Scenes the data supports

| Scene | Where | What shows |
|---|---|---|
| Main window | Downloads | 60 items over six months; marks (Unused, Never opened, Failed download); sort by any column |
| Storage | Storage | Video dominates Downloads; Desktop has a screen recording; what Clear Failed Downloads (about 287 MB) and Find Duplicates would get back |
| Tidy Now | Downloads, ⌘T | Duplicates (Quarterly Report Q3 copies, team photo, recipes, invoice), used installers (Sketchpad, NoteNest, Tasker as a possible match), unpacked zips (brand-assets, course-materials), failed downloads, messy names |
| Confirm and summary | Tidy Now | Files go to the Trash, summary card |
| Undo | Activity | The run just made, Undo, files return |
| Desktop | Desktop | Screenshots with default names, two duplicates, an installer copy, loose files |
| Documents | Documents | Stricter rules: a preview ticks nothing; report-final and report-final-v2, Project Plan and Project Plan (1), Lease and Lease copy |
| Chat | ⌘K | See the warning below |
| Insights | Activity | 10 GB moved to the Trash over twelve weeks, weekly bars by cleanup, running total |

## Chat on the demo home

The plan asked for three questions to give a correct, clean answer three times in a row with the real model: "Which installers have I already used?", "What are my biggest files everywhere?" and "Clean up the duplicates on my Desktop". Measured on 2026-11-21 with a snapshot of the demo home's names (`FolderChatEvalTests.theDemoQuestionsAnswerCleanlyThreeTimes`): **none passed**. The installers question searched by type and ran out of lookups; "everywhere" was refused by the model; the Desktop cleanup searched for files named "Desktop" and ran the duplicate check instead of preparing a card. The model's rules were not changed for the demo, as the plan said. Record the chat shots with several takes, or pick questions that work (a named folder for a count, "Find duplicates on my Desktop"), or decide how to give the folder argument room in the prompt (decision record 0029).
