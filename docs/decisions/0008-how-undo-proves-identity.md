# 0008. Undo, and how it proves it has the same file

Date: 2026-11-14 · Segment: version 0.2, segment 5 (undo from the activity log)

## Decision

**Undo acts only on a file it can prove is the one the change moved.** The proof is in `UndoEvidence`, shared by the planner, the executor and the reconciler. The item at the place the log recorded must:
- be a regular file there (`lstat`, no link followed), with its content on this Mac;
- have the recorded size and modification date (within the executor's 1 ms);
- have the recorded disk ID (inode), when one was recorded;
- have the recorded content hash, when one was recorded and the file can be read.

It must also not be hidden by flag or locked, the same flag checks every change makes. If macOS keeps the content of a Trash item from the app, a matching disk ID stands in for the hash (the owner's choice). A row recorded before the disk ID existed, whose hash cannot be read, is "can't be checked". Undo never looks for a file by name. A change with no recorded Trash location is not undone.

**Places.** A put back takes the item only from directly inside the Trash for the scanned folder's volume (`TrashLocator`; tests give it a temporary folder). Renames and moves are undone only inside the scanned folder, reached through folder handles with no link and no other disk. The original place must be one visible name directly inside the folder the app looks after now, proved by the folder's identity on disk, as the cleanup executor proves it. The scan spells the folder as macOS resolves it (`/private/var/…` for `/var/…`), so comparing paths as text would refuse real files. Every name reaches the system as the log stored it, never rebuilt through a `URL`.

**Never overwriting.** A put back is the same exclusive `renameatx_np` as a rename (`RENAME_EXCL | RENAME_NOFOLLOW_ANY`). Its source is the Trash item's path, because the Trash folder itself cannot be opened without Full Disk Access. Its destination is the original name inside the scanned folder's handle. A taken name fails in the same step as the move, and is reported as "A file with the original name now exists". It is the fourth operation in `DiskChange`, for undo only.

**One executor, one log.** `CleanupExecutor.undo` is a second entry point on the same executor. It uses the same journal, permits and disk calls, a `started` row before each move and the result after it. An undo is a run of its own (`action = 'undo'`, with the action it undid). Each of its rows names the change it reverses (`undoesChangeID`, migration `v2`, which also adds `fileNumber` to every change from now on).

Completing an undone row does all of this in one transaction:
- sets the change's `undoneAt`, once only;
- lowers `totals` by exactly what the change added: its bytes for the Trash, and one file;
- adds to the undo run's own counts.

The intent row goes in only while the step describes the change exactly as the log recorded it (both paths and all the evidence), and the change is done, not undone and not being undone. So a second undo, even from a stale plan, does nothing, and a plan built elsewhere cannot pair a change with another file. A target the log no longer holds (pruned) gives an empty plan. A rename back may find the file itself under its old name (a rename that changed only the letter case or Unicode form); that is not a taker, and the exclusive rename decides. A whole run is undone in the reverse of the order it was made in. The grace period and the rules for what a cleanup may pick do not apply. There is no redo, and folders a move made stay where they are.

**Crash safety.** A crash between a move back and its row leaves the row `started`. At the next launch, before pruning, `UndoReconciler` looks at both places with the row's evidence, which includes the disk ID read right before the move:
- file back and not at the source: completed as undone, exactly as the executor would have;
- otherwise: completed as interrupted, and the change stays undoable if the file is still where it was.

Each row is settled on its own; one whose write fails stays started for the next launch.

Cleanup rows a crash left `started` are not reconciled; they stay interrupted, as record 0006 decided.

## Alternatives

- The content hash only, as the brief first said: without Full Disk Access it may not be readable in the Trash, and every Trash undo would then be refused.
- Requiring Full Disk Access for Trash undo: the strongest proof, but a large permission to ask of every user, for little gain over the disk ID.
- Moving the file back first and hashing it afterwards: acts before proving.
- Asking Finder to put it back (Apple Events): a separate Automation permission prompt, and Finder's move is outside our checks.
- Finding the file in the Trash by name: guesses; a different file with the same name could come back.
- Comparing the original path with the folder as text: refuses real files whenever the scan's spelling differs from the folder's.

## Why

Probed on this Mac (macOS 27.2.1, no Full Disk Access), with ad hoc signed, Hardened Runtime apps launched by `open` so that they had no permissions of the terminal's:

| Step, in an app without Full Disk Access | Result |
|---|---|
| `trashItem` a file from a temporary folder | Moved to `~/.Trash/<name>`, directly inside the folder `url(for: .trashDirectory, appropriateFor:)` names |
| `lstat` an item in the Trash | Allowed for any app: same inode, size and modification date |
| `open` the Trash folder itself (`O_DIRECTORY`) | Refused, `EPERM`, for every app |
| `open` and read an item, once the app has trashed something itself | Allowed, in later launches too |
| The same, in an app that has never trashed anything | Refused, `EPERM` |
| `renameatx_np(AT_FDCWD, <Trash path>, <folder handle>, name, RENAME_EXCL \| RENAME_NOFOLLOW_ANY)` on an item the app trashed | Allowed, in a later launch and after a rebuild with a new code signature (same bundle identifier); same inode and bytes back |
| The same on an item another app or the terminal trashed | Refused, `EPERM`, even for an app that has trashed other items |
| The same onto a name that is taken | `EEXIST`; the other file untouched |

So macOS lets an app take out of the Trash what that app put there, and nothing else, without Full Disk Access. Undo only ever reverses the app's own moves to the Trash, so that is enough; a file the app did not trash fails with "macOS didn't let the app take it out of the Trash", and Finder's Put Back still works. The same app could read its items, so the content hash can normally be checked; the disk ID is the stand-in where it cannot. The terminal is an app like any other here, so shell checks are no guide to what this app may do. `RENAME_NOFOLLOW_ANY` also refuses a path through `/var`, so a Trash path must be the real one; `trashItem` reports `~/.Trash` paths without links.

End to end with the engine in an app launched by `open`: Find Duplicates moved five files of a fake Downloads folder to the Trash in one launch, and a second launch undid the run. All five came back under their names with the same checksums, the totals returned to zero, and planning again found nothing to undo.

## Consequences

- If the bundle identifier ever changes, files the old identity trashed can no longer be taken out of the Trash by the app; Finder's Put Back still works.
- Rename and move rows carry no content hash, so their proof is the disk ID, size and modification date. An edit that keeps the exact size and sets the date back would not be caught. A save that writes a new file changes all three.
- A restored file gets a fresh Date Added, so no cleanup proposes it again for an hour.
- Edit > Undo (⌘Z) means the newest cleanup run only; older runs are undone from Activity. It replaces the standard Undo and Redo, which also removes text editing's undo. The app has no editable text yet; a later search field will need its own.
- Every undo of more than one file asks first, with the count; Return confirms. A single file is undone straight away, and the summary follows either way.
- Rename and move undo is covered by engine tests only until Fix messy names and Archive old downloads have planners.
