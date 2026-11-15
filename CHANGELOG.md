# Changelog

All notable changes to Smart OS File Store are recorded here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Changed

- The main window is wider by default, to fit the sixth column.
- The grace period is now one hour and counts both dates: a file added to the folder or modified in the last hour is never proposed, where version 0.1 skipped only files modified in the last ten seconds. A copy or a file moved in from elsewhere therefore waits an hour too. The rule is checked again right before each file moves, on its Date Added as read at that moment.
- An item named Old downloads at the top of the folder, in any letter case, is never proposed: it is the archive a later version files old downloads into.
- Select None in the preview is now ⌥⌘A, as Deselect All is in Finder. ⇧⌘A shows Activity.
- The main window has a sidebar, like Finder's, with Downloads and Activity. It is wider by default to fit it.
- The summary says how much was moved to the Trash, where it said "freed": the space is free once the Trash is emptied.

### Added

- **Clear Failed Downloads.** It proposes partial downloads that stopped more than an hour ago and never finished, for the Trash:
  - Chrome's and others' `.crdownload` files, Firefox's and others' `.part` files, and Safari's `.download` packages;
  - the reason says when each one stopped, and names a finished file beside it, such as `movie.mp4` beside `movie.mp4.crdownload`;
  - a package counts as changed when anything inside it changes, and the space it frees is the size of what is inside;
  - right before the Trash each item is checked again, and one that changed at all is left alone, since the download may have resumed;
  - hidden items, links and Kept items are never proposed, and undo puts a package back with everything in it.
- A **Clean Up** menu in the toolbar and in the menu bar lists every cleanup action: Find Duplicates (⇧⌘D, unchanged) and Clear Failed Downloads (⇧⌘F). Every action runs through the same steps: progress and Cancel, the preview, the confirmation, the summary with Undo.
- A **Failed download** mark and filter in the file list, for the partial downloads Clear Failed Downloads would propose.
- A Last Opened column: the date macOS records when a file is opened, read from the file itself, so it shows at once in any folder. Files never opened show "Never" and sort as the oldest. Folders, apps, links and Finder aliases, which macOS does not date when they are opened, show a dash unless a date is recorded, and so does any item whose date could not be read.
- Marks, shown as small labelled badges after the name: **Never opened** (no last-opened date, added more than 30 days ago), **Unused** (last opened more than 30 days ago) and **Old** (added more than 90 days ago, opened or not). Folders, apps, links, aliases, hidden items and downloads in progress get no age marks. The thresholds are kept in the app's defaults (`CleanupUnusedAfterDays`, `CleanupOldAfterDays`); there is no settings window yet.
- A filter above the table, also in the View menu: All, Kept, Failed download, Never opened, Unused, Old. The status line then shows how many items match, of how many, and their total size.
- Where a file was downloaded from, as macOS recorded it: the site and the downloading app in a tooltip on the row, and Copy Download Source in the context menu and the Edit menu, which copies the file's address.
- The benchmark also times the scan with and without reading these attributes, the marks, and sorting. The table sorts 10,000 rows in about 22 ms instead of 150 ms (Release, M1).
- A debug-only launch argument, `-GracePeriodSeconds <n>`, so hand testing can use files made moments ago. Release builds ignore it.
- Test fixtures for every version 0.2 action, in the hand-testing script and the shared test helper, and a `FakeApplications` folder beside the fake Downloads folder.
- A benchmark of the scan and Find Duplicates at 10,000 files, kept out of the normal test run, with results in `docs/benchmarks.md`.
- Decision records in `docs/decisions/`.
- The engine can rename a file in the scanned folder and move one into a folder inside it, making the folder if needed. Nothing proposes renames or moves yet. Each action may use only its own operation: Find Duplicates only moves to the Trash, Fix messy names (coming) only renames, Archive old downloads (coming) only moves. Every result names where the file went, and any folder made for it, so a later undo can reverse it.
- The preview can show a plan without groups, one change per row with its checkbox, reason, and old name → new name or folder. Renames and moves are previewed only; they cannot be applied yet.
- Debug builds have a Debug menu with two made-up plans, Show Sample Messy Names Plan and Show Sample Old Downloads Plan, to look at that preview.
- An activity log: every confirmed cleanup is recorded in a local database, `~/Library/Application Support/com.quaden2307.SmartOSFileStore/FileStore.sqlite`, one row per file with the operation, where the file was and where it went, its size, modification date and content hash, the reason, the outcome and the time. The file is readable by its owner only, holds no file content, and never leaves the Mac. Cleanups older than 90 days are removed at launch, at most once a day.
- Activity, a place in the main window's sidebar (also View > Activity, ⇧⌘A): cleanups newest first, each opening to its files, with Reveal in Finder for a file that is still where the log says it went.
- The status line shows everything moved to the Trash so far, a total that pruning never lowers.
- GRDB 7.12.0 (SQLite), the app's first and only dependency, linked to the engine alone and pinned to the commit of that release.
- While a debug override chooses the scan folder, the log is a separate database under the temporary directory, so hand testing never touches the real one.
- Undo, for one change or a whole cleanup: Undo buttons on each cleanup and each file in Activity (greyed out with the reason when a change can't be undone, such as "The Trash was emptied" or "A file with the original name now exists"), an Undo button in the cleanup summary, and Edit > Undo (⌘Z), named after the newest cleanup ("Undo Find Duplicates"). Edit > Undo Selected and the context menu undo what is selected in Activity. Undoing more than one file asks first, with the count. A summary then lists what was put back and what was not, and the file list refreshes.
- Each undo is listed in Activity as its own entry, the undone changes show when they were put back, and the "moved to the Trash" total goes down by what was put back.
- Keep This File (⌘K, in the File menu and the context menu): marks the selected files and folders Kept, so no cleanup ever proposes them. The same item reads Stop Keeping when everything selected is already Kept. Kept items show a Kept badge and have their own choice in the filter. File > Stop Keeping All asks first, with the count. In the preview, Keep This File (context menu or ⌘K) takes a file out of the plan and marks it Kept.
- Kept follows the file, not its name: a Kept file renamed or moved within the folder stays Kept, and a different file that later takes its name is not Kept. A Kept file that no longer exists is forgotten quietly. Editing a Kept file in an app that saves by writing a new copy (most document apps) makes it a new file, which is not Kept.
- When one copy of a duplicate is Kept, Find Duplicates keeps that copy, whatever its name, and proposes the others. Kept copies are never proposed.

### Safety

- Undo puts a file back only when it can prove it is the same file: at the place the log recorded, with the recorded size, modification date and disk ID, and the recorded content when it can be read. It never looks for a file by name and never replaces anything: a taken original name leaves the file where it is. A change can be undone once. An undo interrupted by a crash is settled at the next launch from what is on disk.
- A rename or a move never replaces anything: it is one exclusive step, so if anything already has the name, including in another letter case or Unicode form on a default APFS volume, nothing changes and the file is reported as left alone. No other app can slip an item in between a check and the rename.
- Renames and moves look up every name through a handle on the scanned folder, never through a path, follow no symbolic link, and stay on the folder's disk. A move's destination must lie inside the folder, and a link or a hidden folder on the way is refused, wherever it points.
- A new name must be one valid name that fits the disk. It may not be hidden, the archive's name or that of a download still in progress. Only regular files are renamed or moved, and each is checked again right before it changes, with the same rules as the Trash.
- Every call that changes the disk now lives in one file, and a source-scanning test holds it to exactly four: the Trash, the exclusive rename, making a folder, and making the activity log's own empty database file, which is exclusive too and can never empty or replace a file.
- A file is never changed before the log says so. A row that says the change was started, with any folders a move is about to make, is written and synced first and completed right after, so if the app crashes or is force-quit at most one file's outcome is unknown, and the log shows it as interrupted. The compiler enforces the order: the calls that change a user's file need a permit only that row provides.
- If the log cannot be written, the cleanup stops: the file being looked at is left untouched, the files after it are not touched, nothing is tried twice, and the summary says which file, if any, was changed without its row being completed.
- Without a working log nothing can be cleaned up. A damaged or unreadable database is found when the app opens it, and the app offers to start a fresh log; the old file is renamed aside, never removed, and its folders are never reached through a link.
- A Kept file is never changed, even if it was marked after its preview appeared: the Kept list is checked again right before each change, in the same step as the change's row is written, and a file without a row is never changed. If the list cannot be read, the cleanup stops with the file untouched, and Find Duplicates does not search without it. A fresh log starts with no Kept files, and its offer says so.

## [0.1.0] - 2026-11-13

### Added

- A window listing the top level of the Downloads folder: name, kind, size, date added and date modified, sortable by any column, with Quick Look (Space, ⌘Y) and Reveal in Finder (⌥⌘R).
- Find Duplicates (⇧⌘D): finds files with identical content by grouping on size and hashing only files that share a size, with streamed SHA-256 so memory stays flat for files of any size. Keeps the cleanest-named copy, the oldest on a tie. Empty files, folders, packages, symbolic links, hidden files, in-progress downloads and files modified in the last ten seconds are never candidates.
- A preview with a checkbox per duplicate (Space ticks, ⌘A and ⇧⌘A select all or none), a confirmation sheet whose Return and Escape both cancel (⌘⌫ confirms), progress while files move, and a summary of what moved and what did not, with a reason for each.
- A debug-only folder override (`-ScanFolder <path>` or `SMARTOS_SCAN_FOLDER`) and a script that builds a throwaway fixture folder, so cleanups are never tried on real files during development. Release builds ignore the override.
- Continuous integration that builds and tests both the Debug and the Release configuration.

### Safety

- The engine's only removal call is `FileManager.trashItem`; nothing is ever deleted permanently, and a source-scanning test keeps it that way.
- Nothing changes on disk before the user confirms, and no code path skips the preview.
- Every confirmed file is checked again right before it moves: still a regular file directly inside the scanned folder, same size, date and content, kept copy still present with the same content, not locked, hidden or a cloud placeholder. Anything that changed is skipped and reported. Hard links of one file are never treated as duplicates of each other.
- Files added, removed or renamed while a scan, a hash or a cleanup is running are tolerated and reported, never guessed about; cancelling stops work within milliseconds.
- The app is built with Hardened Runtime, and Release builds carry no debugger entitlement, so the bundle can be notarized later. The engine framework is linked statically, because Hardened Runtime refuses an embedded framework signed only to run locally.
- Logs use the unified logging system with file paths marked private and never include file contents.
