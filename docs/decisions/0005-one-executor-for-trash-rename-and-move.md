# 0005. One executor for the Trash, rename and move

Where the activity log records a change is now decided by [0006](0006-activity-log-schema-and-crash-safety.md): before the last look, not at `beforeChange`.

Date: 2026-11-14 · Segment: version 0.2, segment 3 (rename and move in the engine)

## Decision

**One executor.** `TrashExecutor` became `CleanupExecutor`, which carries out all three operations. `TrashExecutor` remains as a type alias, so Find Duplicates' tests run unchanged (the owner asked for that). The loop (deduplication, cancellation between items, progress, logging) is shared. Each item then goes through the per-item folder check, the action's allowed operation, and its operation's own checks: `CleanupExecutor+Duplicates` (the Trash checks) or `CleanupExecutor+Relocation` (rename and move). Both share one helper for the rules every action shares (hidden, grace period by Date Added read now, size and date as scanned, locked) and one for the last look. The Trash checks are picked by an exhaustive switch on the action, so an action that trashes must bring its own checks. Every call that changes the disk lives in `DiskChange.swift`: `trashItem`, `renameatx_np` and `mkdirat`, once each. `SafetyTests` holds that to the exact count, and checks that the rename carries `RENAME_EXCL`.

**Each action has one operation.** `CleanupAction.allows` is the single rule: Find Duplicates may only trash, Fix messy names may only rename, Archive old downloads may only move. The two new actions have no planner yet (owner's choice, so that tests and the Debug menu's samples carry honest labels).

**Exclusive renames through folder handles.** The scanned folder is opened once per run as a file descriptor, and its identity is checked against the plan's. Every name is looked up relative to that descriptor, never through a path. The change is `renameatx_np(folder, name, destination, newName, RENAME_EXCL | RENAME_NOFOLLOW_ANY | RENAME_RESOLVE_BENEATH)`. With `RENAME_EXCL` the volume itself refuses, in the same step, when anything already has the new name, so there is no check-then-rename gap. The executor does not check the destination beforehand at all.

**A move's folder is walked, never followed.** Each folder on the way is opened inside the one before with `O_DIRECTORY | O_NOFOLLOW`. A symbolic link is refused wherever it points, and so are a folder hidden by flag and a folder on another disk. A missing folder is made with `mkdirat` inside its parent's descriptor, after the last look at the file and the `beforeChange` call. The file gets a last look again right before the rename. Folders made are reported with the item (`createdFolders`) whatever its outcome, so the activity log can undo them.

**Rules for names.** A new name is a single name: not empty, not `.` or `..`, no `/` or NUL, and at most `_PC_NAME_MAX` UTF-16 code units. It may not be hidden, the archive's name or an in-progress download name. A folder on the way may not be hidden or a package. Name equality is left to the volume. Our only comparison is a byte-for-byte "same name" check that skips a rename that would change nothing.

**Scope for now.** Only regular files are renamed or moved, as for the Trash. A `beforeChange` callback runs once an item has passed its checks, immediately before its first change on disk (making a folder, or the change itself). The activity log will record intent there before anything happens, and tests use it to create a destination at that exact moment.

## Alternatives

- A separate rename executor beside `TrashExecutor`: two places that change the disk, and two loops to keep in step.
- A dispatcher in front of an unchanged `TrashExecutor`: the Trash checks stay untouched, but the dispatcher would need its own loop and the disk calls would still be split.
- `FileManager.moveItem`: refuses an existing destination by checking first, so another app can create it in the gap. It also resolves the whole path, links included.
- `rename(2)` after an existence check: the same gap, and it replaces whatever won the race.
- `renamex_np` with absolute paths: links anywhere in the folder's path are followed. `RENAME_NOFOLLOW_ANY` on a full path fails on the temporary folder, which lives under the `/var` link.
- Link then unlink: not atomic, and removing the old name is a deletion the rules forbid.
- `NSFileCoordinator` (the open question in record 0001): not yet. Coordination can wait without limit on another app's file presenter. The Trash path does not coordinate either. Renames within one volume leave every open descriptor working. It can be wrapped around `DiskChange` later without changing plans or results.

## Why

Measured with a scratch probe on this Mac (macOS 27.2, APFS, case-insensitive):

| Case | Result with `RENAME_EXCL` |
|---|---|
| `a.txt` → `A.txt` (letter case only) | Renamed, new spelling stored |
| `café` NFC → NFD (normalisation only) | Renamed, new bytes stored |
| Onto a hard link of the source | `EEXIST` |
| Onto another file | `EEXIST` |
| Symbolic-link source, with `RENAME_NOFOLLOW_ANY` | Renamed the link itself, so the executor's own `lstat` check is what refuses links |
| `openat(O_NOFOLLOW | O_DIRECTORY)` on a link to a folder | `ENOTDIR`, not `ELOOP`; the executor reads the item to tell a link from a file |

So no fallback is needed for case-only or normalisation-only renames: the volume treats the new name as the item's own.

The longest name the volume takes is 255 UTF-16 code units, not 255 bytes: 255 × "a", 255 × "é" (510 bytes), 255 CJK characters (765 bytes) and 127 emoji fit, 128 emoji do not. `pathconf` reports 255 without the unit.

A file URL built with `appending(path:)` or `URL(filePath:)` decomposes the name (NFD), so a file written through one is stored NFD. The scan's URLs keep the form the volume stores, NFC included. So the executor compares a rename's new name, byte for byte, with the scan's name, never with a URL it built. The rename passes the plan's name to the kernel exactly as given, so the stored form is the planner's choice. The URLs in results may show the NFD form, which names the same file on APFS.

## Consequences

- Fix messy names and Archive old downloads only need a planner and their wording. Until then the preview shows their plans (one row per change, before → after) but offers no apply button, and `CleanupPreviewModel` refuses to execute them. Still worded for the Trash and Find Duplicates, so left for those segments:
  - the confirmation sheet, the progress line, and the summary's headline and outcome texts;
  - the "Run Find Duplicates again" skip messages;
  - the "Couldn't move it to the Trash" error.
- Archive old downloads will decide its own destination rule: today the executor accepts any folder inside the scanned folder, at any depth.
- Folders and packages are never renamed or moved. The action that needs them adds checks for their contents (see record 0001's consequences).
- A move into a new folder gives the file a fresh Date Added there. The archive is never a candidate, so nothing waits on that. A file moved back by a future undo will wait out the grace period again.
- Leftover gap: a folder on a move's way could be moved out of the scanned folder after it was opened and before the rename, carrying the file with it. Nothing is overwritten or lost, and the window is a few system calls long, the same kind of gap the Trash check accepts between its last look and `trashItem`.
