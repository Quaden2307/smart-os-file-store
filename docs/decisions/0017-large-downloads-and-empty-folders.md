# 0017. Review Large Downloads and Remove Empty Folders

Date: 2026-11-16 · Segment: version 0.2, segment 13 (the two review lists)

## Decision

### Review Large Downloads

**Size on disk.** The scan already calls `lstat` on every item for its identity; the same call now gives `st_blocks × 512`, the space a file really takes (`FileRecord.allocatedSizeInBytes`). A sparse file or a cloud placeholder counts what it occupies, not its length. A package (`isPackage`, such as an `.app`) is read inside by the existing bounded reader (`PackageContents`, `lstat` semantics, no link followed), which now also totals allocated blocks; its record carries those contents, so its size and last change for the recheck and for undo are its contents', as for a Safari `.download`. Packages get bigger limits (`Limits.package`: 25,000 items, 32 levels) than downloads (`Limits.standard`: 1,000 and 16). A package beyond them has no known size and is not listed. Undo reads every folder with the bigger limits, which reads anything the smaller ones read in full the same way. The reader stops between folders when its task is cancelled. Two contents are equal when their count, size and newest date are; the space on disk is left out, since compression or iCloud eviction changes it without a change the user would see. Plain folders are still never opened for this action.

Because a package's record now carries its contents, the grace period for every action counts from the newest change inside a package, not only the bundle's own date. No other action proposes packages today; one that does must pass the contents to the executor's shared refusal, as Clear Failed Downloads does.

**Candidates.** `LargeFilePlanner`, pure over records: top-level regular files and packages, through the shared eligibility (hidden, archive, in progress, grace period, Kept), at least `CleanupSettings.largeDownloadThreshold` on disk, largest first, then by name. Each is a `.moveToTrash` with the reason `largeDownload(sizeOnDisk:lastOpened:opensRecorded:)`, which is review-only (`isReviewOnly`): the preview ticks none, Select All is hidden for review-only plans, and no automatic flow may tick it. The plan carries `topLevelSizeOnDisk`, the total of every top-level item with a known size, for the footer's share.

**Threshold.** `CleanupLargeDownloadMegabytes` in the defaults, 500 by default; a megabyte is 1,000,000 bytes, as Finder counts. Settings offers 500 MB, 1 GB and 5 GB. Like the day thresholds, any whole number of 1 or more set another way is accepted (tests use 1 MB, and a hand run can pass `-CleanupLargeDownloadMegabytes 100`); anything else gets the default.

**Reason text.** "<size>, last opened <date>" or "<size>, never opened", as asked. When macOS records no open date for the kind (an app, an alias), saying "never opened" would be false, so the reason is just the size. The log stores `<bytes>;<seconds | never | unknown>`.

**Executor.** `trashLargeDownload`: reason and kind must match the plan, the item is found through the folder handle without following links, must still be a regular file (or a real folder for a package), not a placeholder, not hidden; a package's contents are read again; then the shared refusal (grace period on Date Added read now, size and last change as scanned, locked), the journal's Kept check, the last look (same identity, same contents) and `trashItem`.

**Fixture.** `big-video.mov` in `scripts/make-fake-downloads.sh` is now written (`mkfile` without `-n`), so the hand-testing folder has a file that is large on disk; `disk-backup.img` stays sparse and is never listed.

### Remove Empty Folders

**What is empty.** A plain folder holding nothing, or nothing but folders that are empty by the same rule and files macOS makes by itself, listed by exact name: `.DS_Store` and `.localized` (`PackageContents.systemFileNames`). Anything else at any depth, a link or a hidden file included, makes it not empty. `Thumbs.db`, `desktop.ini`, `Icon\r` and `._` files are not on the list: a user can make or need them, and a folder they keep stays, which is the safe side.

**Bounded, and unknown is not empty.** The scan reads each plain top-level folder (never the archive, a package, a link or a `.download`) with the same reader and `Limits.standard`, 1,000 items and 16 levels, and stops at the first item that is not a folder or a system file, so a full folder costs one or two `lstat` calls. Each level's items are looked at before any folder in it is opened, so a folder holding a file beside an unreadable subfolder is simply not empty. The reader never crosses into another volume mounted inside a folder, for any reading. It keeps the contents only when the folder is empty, or the failure when it cannot be told; a folder past the limits fails with `tooManyItems` and is not empty. A folder that cannot be read is listed under Not checked; one past the limits is not, as with downloads.

**Plan and run.** `EmptyFolderPlanner`, pure over records, proposes `.moveToTrash` with the reason `emptyFolder`, ticked, in name order. The shared rules keep out the archive, hidden folders, the grace period (counted from the newest change inside, `lastChange`) and Kept. `trashEmptyFolder` finds the folder through the handle without following links, refuses a placeholder, reads it again and refuses it unless still empty (`changedSinceScan`), applies the shared refusal on that reading, asks the journal, then reads it again at the last look and requires the same contents. Undo reads the folder in the Trash the same way as any folder.

## Alternatives

- **Logical size (`fileSize`).** Rejected by the prompt: sparse files and cloud placeholders would be overstated.
- **`URLResourceKey.totalFileAllocatedSizeKey`.** Equivalent for files, but packages are summed by the `lstat` walk anyway; one source for both keeps them consistent.
- **Reading packages in the planner.** Rejected: planners stay pure over records, and the scan already reads `.download` packages the same way.
- **Unlimited package walk, or 100,000 items.** Rejected: every scan, for every action, would pay for an Xcode-sized bundle. The 25,000 bound is a recorded shortcut.
- **Empty folders: the user's own judgement of junk files.** Not done: only what macOS makes by itself is ignored, by exact name.
- **Empty folders: no early stop.** Rejected: every scan would read up to 1,000 items of every folder, when one is enough to know it is not empty.
- **Only the three offered thresholds.** Not done: the day thresholds accept any value set by hand, and tests need a small one.
