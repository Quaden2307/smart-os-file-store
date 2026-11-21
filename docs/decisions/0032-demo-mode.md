# 0032. Demo mode

Date: 2026-11-21

## Decision

- `scripts/make-demo-home.sh` builds a fixed, fictional home (Downloads 60, Desktop 25, Documents 40, a fake Applications folder with three installed apps). It is a separate script from `make-fake-downloads.sh`, which stays the test fixture with its edge cases; the demo home is for looks, the fixture for coverage. Path checks (tested in `DemoHomeScriptTests` with `DEMO_DRY_RUN`) refuse the real home, folders in it, system places and folders holding files it did not make; it deletes only a folder it marked.
- Large files are APFS clones (`cp -c`) of one written file with a tail of their own: each reports its full size and full allocated size, so the table and the storage view show believable numbers, while the disk holds the blocks once. Sparse files were rejected: their allocated size is tiny, and the storage view counts space on disk.
- `scripts/run-demo.sh` builds and opens the debug app with the demo flags; `--reset` rebuilds the home and removes the debug build's log folder for that home, found with `scripts/demo-log-folder.swift`, which hashes the path as `ActivityLogLocation` does.
- New debug-only arguments: `-WindowSize WxH` (centred), `-SkipWelcome`, `-TurnOnStandardFolders`, `-SeedDemoHistory`, `-StartPlace`, `-SnapshotTo`, `-SnapshotDark`. Release builds ignore them all.
- History is seeded through the log's own recording calls with past dates (`DemoHistory`), only for a demo home whose log has no run. The demo home's log is the debug build's own temporary one, never the real one (`ActivityLogLocationTests` cover that an override never resolves to the real log).

## Not done

- Settings changed in a demo still go to the app's normal preferences: `@AppStorage` reads the standard defaults throughout, and giving the demo a defaults suite of its own touches every view. Noted in docs/demo.md.
- The three chat questions did not pass with the real model (docs/demo.md); reported, model rules unchanged, as the plan asked.
- README screenshots of a preview sheet and the chat: off-screen drawing does not show sheets or live answers.
