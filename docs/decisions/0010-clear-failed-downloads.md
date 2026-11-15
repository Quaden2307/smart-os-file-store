# 0010. Clear Failed Downloads, and how the app holds several actions

Date: 2026-11-15 · Segment: version 0.2, segment 7 (Clear Failed Downloads)

## Decision

**When a partial download counts as failed.** A candidate is a file ending in `.crdownload` or `.part`, or a folder ending in `.download` (Safari's, which macOS shows as a package where Safari's type is registered, and as a plain folder elsewhere; both are accepted). The name alone decides what the item must be (`FailedDownloadPlanner.partialShape`), and the planner, the executor and the Failed download mark all use that one rule. It is failed once nothing about it has changed for the shared grace period (one hour):
- **A file:** its modification date, which moves whenever it grows, and Date Added.
- **A folder:** its *last change*, the later of the folder's own date and the newest date of anything inside it (`FileRecord.lastChange`). Writing to the partial file inside moves only that file's date; adding or removing an item moves only the folder's. So both count. An empty folder counts by its own date.

Hidden items, links and Kept items are never candidates, and the archive's name is refused as for every action. It is the one action that lets downloads in progress take part: `CandidateEligibility.refusal(…, downloads: .allowed)` skips only that one rule.

**The scan reads inside `.download` folders and nowhere else.** `PackageContents` counts the items inside, adds up the sizes of the files, and keeps the newest date. Every item is described with `lstat` semantics, so a link inside is counted as itself and never followed. A folder inside is opened only directly (`O_NOFOLLOW`), through a handle on the scanned folder.
- It stops at 1,000 items or 16 levels. A folder that big is not a download, so it is left out and not reported.
- A folder that is only in iCloud (`SF_DATALESS`) is never listed, since listing it would download it.
- A folder that cannot be read is listed under Not Checked with the reason.
- The same reader runs at scan time, again right before the Trash, and again before undo, so all three compare like with like.

**The recheck is size and last change, not a hash.** The proposed change carries the file's size, or the folder's content total, and its last change. Right before the move the executor reads both again through the folder's handle, together with Date Added. Any difference, or a last change inside the hour, means the download may have resumed, and the item is skipped as `changedSinceScan`. The last look, after the activity log's row, reads a folder's contents once more. A partial download is incomplete by definition, so there is no content to compare it with, and a resumed download always moves a date.

**The finished file in the reason.** The reason names an item beside the partial whose name is the partial's without its last extension, compared case-insensitively (`movie.mp4` beside `movie.mp4.crdownload`). That item must be a non-empty file or a package. An empty file is not named, because Firefox makes an empty placeholder under the final name when a download starts.

**Undo of a folder: `changes.isFolder` (migration `v4`).** A trashed folder keeps its disk ID, its own date and its size in the Trash. This was probed on macOS 27.2 with `trashItem` and an exclusive rename back. `trashItem` hands back a path without a trailing `/`, while `contentsOfDirectory` gives folder URLs one. So every path the log stores drops it (`URL.storedPath`): `lstat("x/")` would follow a link at `x`. For a folder row, undo proves the item as follows:
- **A look at the folder** (planner, reconciler, executor): it must be a folder, with the recorded disk ID. A folder row without a disk ID cannot be checked.
- **The contents** (executor only): their total and last change must match what was recorded, as a hash does for a file. If macOS keeps the Trash's content from the app, the matched disk ID stands in, as it does for a hash.

So Activity can offer Undo for a folder whose contents changed in the Trash, and the executor then refuses it as changed. No folder row records a hash, so nothing ever hashes a folder. Every row written before `v4` is a regular file, since no action could change anything else.

**One definition and one display entry per action.**
- **Engine:** `CleanupAction.definition` gives the identifier the log stores (written out, unchanged for the existing actions) and the kind of plan (`operation`). `allows` and the log codes derive from it.
- **App:** `CleanupAction.display` gives the titles, explanation, symbol, shortcut, progress words and empty-preview words.
- Adding an action means adding one entry in each. Then:
  - state its planner in `CleanupPlanners` (`plan` and `hasPlanner`);
  - give it trash checks in the executor's dispatch, if it trashes.

**One flow, two menus.** `CleanupSearchModel` runs any action the same way:
- it reads the Kept list fresh;
- it plans through `CleanupPlanners`, with progress and Cancel;
- it shows the shared preview, then the confirmation;
- it executes, then shows the summary with Undo;
- it logs the run, then refreshes the list.

The toolbar's Clean Up menu and the menu bar's Clean Up menu list `menuActions`, the actions with a planner. Only the menu bar holds the shortcuts (Shift-Command and a letter: ⇧⌘D, ⇧⌘F, the owner's choice), so no key is claimed twice.

## Alternatives

- A hash of the partial file as the recheck: it would read a large partial for nothing; a resumed download moves its date anyway.
- The folder's own date alone for a `.download` folder: misses Safari writing to the file inside.
- Following links inside a `.download` folder: could reach anything on the disk and count it.
- Requiring Safari's `Info.plist` inside: not part of the decided behaviour; the name and the hour decide.
- Storing undo evidence for folders as the folder's own `lstat` size and date: the space-freed counter would then count about 100 bytes per folder, not its contents.
- Listing actions without a planner yet (Fix Messy Names, Archive Old Downloads) as disabled menu items: they arrive in their own segments.
- Numbered shortcuts (⌥⌘1, ⌥⌘2…): would have moved Find Duplicates off ⇧⌘D.

## Why

The rules come from the owner's decided behaviour. The checks follow the rest of the engine: a recheck right before the change, nothing guessed from a partial reading, and no link followed.

## Consequences

- The Failed download mark, like the age marks, is as of the scan, so it can lag the planner by up to an hour until the next refresh. The planner checks the time again when it runs.
- The status line's totals count a folder as 0 bytes, as before. The preview and the space-freed counter count a `.download` folder's contents.
- A partial put back by undo has a new Date Added, so it is protected by the grace period for an hour before it is proposed again.
