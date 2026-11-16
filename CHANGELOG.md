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
- **Remove Unpacked Zips.** It proposes, for the Trash, a zip whose every item already sits next to it, unpacked, at the same size. What it was unpacked to is never touched:
  - it looks where Archive Utility unpacks: one item beside the zip, several in a folder named after it, or a numbered name such as `project 2` when the name was taken;
  - every file is compared by its path and size, so a matching name alone never counts. Extra files in the unpacked folder are fine. The `__MACOSX`, `.DS_Store` and `._` entries Finder's Compress adds are left out;
  - the reason names the unpacked item: "Already unpacked to project";
  - a zip holding an app is left for the installers action. Empty zips, `.jar` and `.docx` files are never proposed;
  - so are hidden, linked and Kept zips, and anything added or changed in the last hour. That includes an unpacked copy that arrived in the last hour or holds a file written in it; opening the copy in Finder does not count;
  - a zip that can't be read is listed under Not checked with the reason: damaged or cut short, its list of contents encrypted, too large to check, or names in an old encoding. A password-protected zip whose list can be read is treated like any other;
  - right before the Trash, the zip and its unpacked copy are both checked again, and one that changed is left alone. Undo puts the zips back.
- **Remove Used Installers.** It proposes, for the Trash, a disk image, an installer package or a zip holding an app at its top level once that app is installed in `/Applications` or `~/Applications`:
  - ticked when the app's identifier matches and the installed version is the same or newer; for a package, when its receipts match too and the apps it installs are still there. A package that installs no app matches on its receipts;
  - unticked, labelled "Possible match", when only the name matches, versions and words such as `arm64` left out; never when the installed app is older than the installer's, or when a disk image is open;
  - an installer holding several apps is ticked only when every one is installed; there is no waiting period after an install;
  - nothing in an installer is run, and nothing is written into it: a zip's `Info.plist` is read in memory, a package's description without its payload, and a disk image is checked by macOS's own checker, mounted read-only and hidden from Finder, then always ejected, also after a cancel or an error. An image that asks for a password or a licence is never opened;
  - an installer that could not be read and matches by no name is listed under Not checked, with why;
  - what was read is kept, so the next search opens no disk image again; right before the Trash, the installer and its installed app are checked again. Undo puts installers back.
- **Fix Messy Names.** It proposes a clean name for a file with copy numbers or leftover junk in its name:
  - five rules, and only these: decode percent-encoding (`%20`) when the whole name is valid text and no separator or control character results; remove a web address's leftover after the extension (`?` or `_` followed by `dl=0`, `dl=1`, `raw=1`, `raw=true`, `download=1` or `download=true`, and `@download`); remove a doubled extension; remove a copy suffix (` (1)`, ` copy`, ` copy 2`, by the same rule Find Duplicates uses); then tidy the spaces, dots and underscores left at the ends;
  - letter case, dates, version numbers, words and the extension are never changed, and a name that would be left empty is left alone;
  - when the clean name belongs to a file with the same content, nothing is proposed, since Find Duplicates handles it; when it belongs to a different file, the file's date added is put in the name (`invoice 2026-11-13.pdf`), then ` v2`, ` v3`; when two files want one name, the older gets it;
  - names are compared the way the disk compares them, so `Report.pdf` and `report.pdf` clash on a normal Mac disk;
  - the reason says what was removed ("Removed (2)", "Decoded %20"), and the preview strikes out what each name loses and shows what it gains in bold;
  - right before each rename the file is checked again, and a name that has been taken since is skipped, never replaced and never swapped for another name. Undo gives the old names back.
- The preview can now carry out renames: Rename asks "Rename N files?", where Return renames and Escape cancels.
- An **Installed** mark and filter for installers whose app is installed, from what Remove Used Installers has read; drawing the list opens no installer.
- A debug-only launch argument, `-ApplicationsFolder <path>`, for hand testing against a fake Applications folder. Release builds ignore it.
- **Review Near-Duplicates** (⇧⌘R). It lists files whose names are the same once cleaned, such as `report.pdf` and `report (1).pdf`, but whose content differs, under the title "Similar names, different content":
  - nothing is ticked and no file is chosen to stay; tick only what you want in the Trash, and the confirmation asks first;
  - each row shows the size, Date Added, Date Modified and Last Opened, with "Newest" and "Largest" as facts, and the reason "Same name as notes.txt, different content";
  - one file of each group always stays: the last one can't be ticked, and the engine refuses a run that would move them all;
  - files with identical content are left to Find Duplicates: a group shows one of each and says how many identical copies it has. Different extensions never match;
  - Quick Look works on any row, and Space with two rows selected shows them side by side (in every preview);
  - files read by Find Duplicates earlier in the session are not read again.
- **Archive Old Downloads** (⇧⌘O). It moves the files marked Never opened or Unused, by the same thresholds as the marks, into a folder named Old downloads at the top of the folder, made on first use:
  - the reason says when each was last opened, or that it was never opened and when it was downloaded;
  - a name taken in the archive by a different file gets the file's Date Added (`report 2025-01-01.pdf`, then ` v2`); a name taken by an identical file sends this copy to the Trash instead, and the confirmation says how many;
  - folders, apps, links, hidden files, downloads in progress, Kept files and anything added or changed in the last hour are never proposed, and Old downloads and everything in it are invisible to every action;
  - if something called Old downloads is a file or a link, nothing is archived and the preview says why;
  - moving keeps the file's last-opened date, download source and Date Added (macOS would otherwise reset Date Added on a move), so Undo puts each file back exactly as it was; the empty Old downloads folder stays.
- A **Settings** window (⌘,): when files count as unused (30, 60 or 90 days) and as old (90, 180 or 365 days), with the marks updated at once, and where the activity log is stored, its size and Reveal in Finder.
- Double-clicking Old downloads in the list opens it in Finder.
- **Review Large Downloads** (⇧⌘L). It lists the files and packages (such as apps) at the top of the folder that take at least 500 MB on disk, largest first, for review:
  - the size is the space each really takes on disk, so a sparse file or a cloud file that is not downloaded is not overstated; a package counts everything inside it;
  - nothing is ticked, and Select All is not offered: tick what you want in the Trash;
  - each row shows the size on disk, kind, Date Added, Last Opened and where it was downloaded from, and the reason says "1.2 GB, last opened 3 Mar 2026" or "1.2 GB, never opened" (an app, whose openings macOS does not date, shows only its size); Quick Look works as everywhere;
  - the footer says how much of the space taken by the folder's files the list accounts for;
  - folders, links, hidden items, downloads in progress, Kept items and anything added or changed in the last hour are never listed;
  - Settings has "List downloads as large from" 500 MB, 1 GB or 5 GB.
- **Remove Empty Folders** (⇧⌘E). It proposes for the Trash, ticked, the folders at the top of the folder that hold nothing, or nothing but Finder's `.DS_Store` and `.localized` files and folders that are empty themselves ("Empty folder"):
  - a folder holding any other item at any depth, a link included, is not empty, and neither is one too deep (16 levels) or too full (1,000 items) to check, or one the app cannot read, which is listed under Not checked;
  - Old downloads, apps and other packages, links, hidden folders, Kept folders and folders added or changed in the last hour are never proposed;
  - right before the Trash each folder is read again, and one that is no longer empty is left alone; Undo puts the folders back.
- A **Clean Up** menu in the toolbar and in the menu bar lists every cleanup action: Find Duplicates (⇧⌘D, unchanged), Clear Failed Downloads (⇧⌘F), Remove Unpacked Zips (⇧⌘U), Remove Used Installers (⇧⌘I) and Fix Messy Names (⇧⌘M). Every action runs through the same steps: progress and Cancel, the preview, the confirmation, the summary with Undo.
- A **Failed download** mark and filter in the file list, for the partial downloads Clear Failed Downloads would propose.
- A Last Opened column: the date macOS records when a file is opened, read from the file itself, so it shows at once in any folder. Files never opened show "Never" and sort as the oldest. Folders, apps, links and Finder aliases, which macOS does not date when they are opened, show a dash unless a date is recorded, and so does any item whose date could not be read.
- Marks, shown as small labelled badges after the name: **Never opened** (no last-opened date, added more than 30 days ago), **Unused** (last opened more than 30 days ago) and **Old** (added more than 90 days ago, opened or not). Folders, apps, links, aliases, hidden items and downloads in progress get no age marks. The thresholds are kept in the app's defaults (`CleanupUnusedAfterDays`, `CleanupOldAfterDays`), which Settings sets.
- A filter above the table, also in the View menu: All, Kept, Failed download, Installed, Never opened, Unused, Old. The status line then shows how many items match, of how many, and their total size.
- Where a file was downloaded from, as macOS recorded it: the site and the downloading app in a tooltip on the row, and Copy Download Source in the context menu and the Edit menu, which copies the file's address.
- The benchmark also times the scan with and without reading these attributes, the marks, and sorting. The table sorts 10,000 rows in about 22 ms instead of 150 ms (Release, M1).
- A debug-only launch argument, `-GracePeriodSeconds <n>`, so hand testing can use files made moments ago. Release builds ignore it.
- Test fixtures for every version 0.2 action, in the hand-testing script and the shared test helper, and a `FakeApplications` folder beside the fake Downloads folder.
- A benchmark of the scan and Find Duplicates at 10,000 files, kept out of the normal test run, with results in `docs/benchmarks.md`.
- Decision records in `docs/decisions/`.
- The engine can rename a file in the scanned folder and move one into a folder inside it, making the folder if needed. Nothing proposes renames or moves yet. Each action may use only its own operation: Find Duplicates only moves to the Trash, Fix messy names (coming) only renames, Archive old downloads (coming) only moves. Every result names where the file went, and any folder made for it, so a later undo can reverse it.
- The preview can show a plan without groups, one change per row with its checkbox, reason, and old name → new name or folder. Renames and moves are previewed only; they cannot be applied yet.
- Debug builds have a Debug menu with a made-up plan, Show Sample Old Downloads Plan, to look at that preview. (Removed again once Archive Old Downloads arrived.)
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
- Zips are only ever read. The app reads a zip's list of contents and its headers, never the files inside: nothing is extracted, and no entry's path is ever used to open or write anything.
  - It refuses an archive that declares more than 100,000 items or a list larger than 32 MiB before it allocates for it, and a name longer than 1,024 bytes before reading the name. It also refuses an archive whose paths imply more folders than it checks.
  - It refuses a zip that different tools would read differently: bytes after its end, a second end record, Zip64 and classic end records that disagree, or local headers that differ from the list or hide an entry it leaves out. So a crafted zip cannot show one list of contents and unpack another.
  - Every byte it reads is bounds-checked.
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
