# 0026. Managed folders: the engine learns about more than one folder

Date: 2026-11-20 · Segment: Folders, segment 1

The engine assumed one folder: Downloads, or a debug override. Now every plan, run, undo and Kept mark belongs to a managed folder with an ID of its own, the list of folders lives in the activity log, and one set of rules says which folders may be managed. Nothing visible changes: the app still shows Downloads only, and no cleanup behaves differently.

## Decisions

### The model

- **`ManagedFolder`** has an `id` (a UUID made once and stored, never the path), a `kind` (downloads, desktop, documents, custom), a `displayName`, a `locator` (how it is found again) and the `url` where it was found this launch. Two values are equal when their IDs are: a folder found at a new place, or with a renewed bookmark, is the same folder.
- **`url` keeps today's spelling** (`standardizedFileURL`). Links are resolved only to judge the folder by the rules. The log stores paths as text and undo compares them, so resolving the spelling would have turned every older run in a linked Downloads, or under `/var`, into a run of "another folder".
- **A standard folder is found by asking the system each launch** (`FileManager.urls(for:in:)`), in `FolderRegistry` and nowhere else in the engine. `SafetyTests.onlyTheRegistryLooksUpTheStandardFolders` pins that.
- **A custom folder is found through a bookmark.** The app is not sandboxed, so it does not need one for access. It uses one because a stored path fails in the two ways that matter here: after a rename or a move the path leads nowhere, and a different folder made at the old place would be taken for the managed one and cleaned.
- **A bookmark alone is not enough.** macOS resolves a bookmark by its old path first and takes whatever folder is there now (a test showed it). So a custom folder's row also holds which folder it is on its volume (volume UUID and file number, as `keptItems` holds a file). When the bookmark leads to another folder, the real one is looked for by that number (`fsgetpath`); if it is gone, the folder is not found.
- **`displayName`** is stored for a custom folder only. A standard folder's is its name on disk; the app puts the kind into words itself, so no English word goes into the log.
- **`FolderRegistry`** lists, adds and removes folders and finds each one. It holds no database: every call takes the log. The list starts with Downloads only. A custom folder is found through its new bookmark before its row is written, so one that cannot be found again never gets onto the list.
- **`locator`** (how a folder is found again) is part of the value because the owner's model names it. Nothing reads it yet: the registry finds a folder from its row.
- **Removal keeps the row** (`removedAt`), so an old run still names its folder and can be undone. A standard kind put back on the list gets its old ID back.

### The database (migration `v7`)

- **`folders`**: `id` (the UUID as text; GRDB binds a `UUID` as a blob, which a STRICT text column refuses), `kind` (a stable code), `displayName`, `bookmark`, `volumeUUID`, `fileNumber`, `removedAt`. Checks: only a custom folder has a name, a bookmark or an identity; one row per standard kind.
- **`folderID`** on `runs`, `changes` and `keptItems`, a foreign key to `folders`. Every row from before belongs to Downloads, whose row the migration makes with a new UUID.
- **Nullable column, with triggers.** SQLite adds a column only with one default for every database, and the Downloads ID differs per database. Triggers on insert and on update refuse a row without a folder.
- **`changes.folderID` is read from the change's run** in the insert itself, so the two cannot disagree.
- **`runs.folderPath` stays.** Undo's proof needs the path the run saw.
- **What stays global, and why:**
  - `installerFacts`: a cache about a file, keyed by the file.
  - `totals`: the app's one counter of space freed. A folder's share can be worked out from its runs.
  - `maintenance`: housekeeping for the whole database.
  - The thresholds in `UserDefaults`: the owner asked for no per-folder settings in this segment.
  - The Kept list's matching: see below.
- **An older build refuses a v7 log** as made by a newer version, as decision 0006 set out. A copy of the older build still running when this one first opens the real log can no longer record a run; its cleanup stops before changing anything.
- **Migration tests start from frozen copies of v1 to v6.** The earlier tests made an old database by undoing the newest migrations on a current one. SQLite refuses to drop a column that has a foreign key or a trigger, so that no longer works. `Support/LegacyLog.swift` holds each shipped migration's statements, copied and never edited, with rows written the way that version wrote them. The four earlier migration tests are rewritten on it with their assertions kept, and the new test runs from each of the six versions.

### Scanning, planning and executing

- **Every entry point takes the folder**: `FolderScanner.scan`, all nine planners, `CleanupPlanners.plan`, `TidyNowPlanner`, `FileMarker.marks`. A plan, a result and a run start carry `folder`; `folderURL` is still there, read from it.
- **`CandidateEligibility`'s checks take the folder** for one thing: the archive's name, which a check on an item now asks its folder (`ManagedFolder.archiveFolderName`). Every kind has the one name today (the owner's decision below). `isExcludedName` has no default for it: every caller names the folder's, except the rule about a new name (`FileNameRules.isAllowedFileName`), which has no folder and names the one name itself, with a note for the day kinds get their own.
- **A run belongs to one folder, at one place.** `CleanupExecutor.run` is given it. In a Tidy Now, a plan made for another folder, or for the same folder at another path, was dropped without a word; each of its confirmed changes is now recorded and reported as skipped, outside the folder.
- **Nothing outside the plan's folder changes.** The checks from decision 0005 already see to it (the item's parent must be the folder by its identity on disk, names go through one handle on the folder, renames resolve beneath it). `ManagedFolderExecutorTests` proves it with two folders on the log's list: a move to the Trash, a rename and a move whose file lies in the other folder, and a move whose destination does, are refused, and nothing there moves.
- **The log takes no run for a folder it does not hold** (the foreign key). The run never opens, the journal stops, and nothing on disk changes.
- **The content-hash cache** forgets only the files of the folder that was scanned (`keepOnly(_:in:)`), so one folder's scan no longer drops another's hashes.

### Undo

- **Undo finds the run's own folder** by `runs.folderID` (`UndoPlanner.plan(_:log:folders:)`), whatever folder is on screen and whether or not the folder is still on the list.
- **Gone means refused.** A folder that cannot be found (removed from disk, a bookmark that leads nowhere, a place the rules now refuse) gives the existing refusal `folderUnavailable` for every change. No new code was needed.
- **Moved means refused** (the owner's decision). A custom folder found somewhere other than `runs.folderPath` gives the existing refusal `otherFolder`. The log holds each file's whole path; following the folder would need new proof rules for undo (decision 0008), and nobody can add a custom folder from the app yet.
- **The log checks too**: a change is undone only by an undo run of the change's own folder (`recordUndoIntent`).
- **`UndoPlan` carries `folderID` and `folderURL`**, not a `ManagedFolder`: when the folder cannot be found there is none, and the plan still has to say which run's folder it was.
- **The reconciler works per folder.** A row whose folder cannot be found now is left as it was, until the folder is found: at a later launch, or before the next undo, which settles first (`UndoModel.start`). Before, it was settled as "not undone", which would be wrong for a folder on a disk that is not connected. The cost: when the folder is gone for good, the row waits for good and its undo run stays shown as interrupted. "Away" and "gone" cannot be told apart, and the log does not guess.

### The Kept list

- **Kept follows the file everywhere** (the owner's decision; decision 0009 already said a Kept file moved out of the folder stays Kept). Matching is unchanged and looks at every entry, whichever folder it was marked in.
- **`keptItems.folderID` is a record** of where the file was when it was marked. Nothing reads it to narrow the protection.

### Which folders may be managed

`FolderSafetyRules`, one pure type, asked when a folder is added and every time one is found. It resolves links first (`realpath`, which opens nothing) and refuses:

| Refused | How it is judged |
|---|---|
| The home folder, or a folder that holds it | Its names are the start of the home's |
| The top of a disk | `/`, or a folder on another disk than the folder it is in |
| Anything in a Library | In the home's `Library` or `/Library` |
| An application, or inside one | A name on the way ends in `.app` |
| A system location | `/System`, `/Library`, `/Applications`, `/usr`, `/bin`, `/sbin`, `/private`, `/dev`, `/cores`, `/opt`, `/Network` and what is in them; `/Volumes` and `/Users` themselves |
| The Trash | A name on the way is `.Trash` or `.Trashes` |
| The app's own data | The log's folder, the folder disk images are read in, or a folder that holds one |
| A folder inside or holding a managed one | By its names |
| Not a folder | Missing, a file, or a link that leads nowhere |

- Names are compared without regard to letter case or Unicode form, so a rule can refuse one folder too many and never one too few.
- **Downloads gets the same rules** (the owner's decision). A Downloads that leads to a refused place now shows a blocked screen saying why, instead of the list.
- **Cloud-drive folders are refused for now** (the owner's decision): iCloud Drive, Dropbox, OneDrive and Google Drive keep theirs inside the home's Library.
- **The temporary directory is under `/private`.** A debug override, and the tests, name it as exempt from the system-location rule, so a throwaway folder can stand in for Downloads. The exemption is a field of the rules, set only when an override is in use; a Release build has no override and so no exemption.

### Debug overrides

- **`-DemoHome <path>`** (and `SMARTOS_DEMO_HOME`): `<path>/Downloads`, `<path>/Desktop` and `<path>/Documents` are the three standard folders, and the system is never asked for the real ones. A demo home that is the real home is refused.
- **`-ScanFolder`** works as before; under it there is no Desktop and no Documents.
- **Order**: `-DemoHome`, `-ScanFolder`, `SMARTOS_DEMO_HOME`, `SMARTOS_SCAN_FOLDER`. The first that is set applies and the rest are ignored entirely, as before. An override that cannot be used finds no folder; it never falls back.
- **Each override has its own temporary log.** A scan folder's is named as before, so a fake folder from an earlier build finds its log again. A demo home's is named apart, even at the same path.
- Release builds ignore all four (`FolderOverrideTests`, run in Release, shows it).

### Cloud placeholders

A placeholder is a file whose content is not on this Mac (`SF_DATALESS`). Reading one would download it. Every read was already preceded by an `lstat` that refuses one; the audit found the readers clean (the hasher, the zip, package and disk-image readers, the app `Info.plist` reader, the walks of packages and unpacked folders; last-opened and download source come from `getxattr`, which reads no content).

The scan now keeps the flag on the record (`FileRecord.isDataless`), and each planner that reads content checks it at the point where it would read:

| Planner | A placeholder |
|---|---|
| Find Duplicates | Never read. Listed as not checked (not downloaded) when it shares a size with another file; never a duplicate |
| Review Near-Duplicates | Never read. Not checked; never in a group |
| Remove Unpacked Zips | The zip is not read. Not checked |
| Remove Used Installers | Not read. A disk image or package is not checked; a zip is left out without a word, as any zip that is not an installer |
| Fix Messy Names | Renamed like any file when its clean name is free (a rename reads nothing). Not checked when the name is taken by a file of the same size, where content would decide |
| Archive Old Downloads | Moved like any file (a move inside the folder reads nothing). Not checked when the archive holds a file of that name and size |
| Clear Failed Downloads | Judged by name and dates. Reads nothing |
| Review Large Downloads | Judged by the space it takes on disk, which for a placeholder is next to nothing, so it is never large |
| Remove Empty Folders | A folder kept in the cloud is not listed, so it is not proposed |

- The executor reads the flag from disk right before each change, as before.
- **Two folder opens had no check** and now do: listing the archive folder, and stepping into a move's destination. They can only matter in an iCloud Desktop or Documents. Whether opening such a folder (as opposed to listing it) fetches anything is not known, so the guards are a precaution.
- **No test can make a real placeholder**: the system alone sets the flag. `PlaceholderTests` flags each record as the scan would and makes the file behind it unreadable, so a planner that opened it anyway would report "access denied" and not "not downloaded". It runs on Downloads, Desktop and Documents of a fake home.

### The app

- The file list scans **a provisional Downloads** (`FolderRegistry.provisionalDownloads`): the right place, found without the log and without looking at the disk, under an ID stored nowhere. The first scan is not delayed by the log, and the list still works when the log cannot be opened.
- **The rules are asked before every listing, off the main actor** (`FolderRegistry.refusal(for:)`): where a link leads can change, and a disk that does not answer must not hold the window up. A Downloads that is simply not there is not refused: the listing says "Folder not found" with Try again, as before.
- Cleanups and Keep are offered only while the open log knows Downloads (`ActivityLogModel.downloads`), so nothing is offered that would then do nothing.
- Everything recorded in the log (a search, Tidy Now, an undo, a Kept mark, a cleanup from the chat) takes **Downloads from the same opening as the log** (`ActivityLogModel.downloads`). After Start a Fresh Log the ID is a new one; a stale one would fail the run and close the log.
- Activity judges each run in its own folder, with that folder's Trash.
- The chat module and its prompt templates are untouched.

## The owner's decisions

Asked before any code was written, 2026-11-20:

| Question | Decision |
|---|---|
| Undo of a run whose folder has moved since | Refuse, say why |
| A Kept file that ends up in another managed folder | Still Kept |
| The archive's name in other kinds of folder | "Old downloads" everywhere for now |
| A Downloads that leads to a refused place | Same rules: refused, with a screen that says why |
| Cloud-drive folders | Refused for now |

## Alternatives

- **A fixed, well-known ID for Downloads**, so the column could be `NOT NULL` with a default. Rejected: the owner asked for an ID made once and stored, and two installs would then share an ID that means different folders.
- **Rebuilding `runs`, `changes` and `keptItems`** to get `NOT NULL`. Rejected: three table rebuilds of the user's history for what two triggers per table give.
- **A path instead of a bookmark** for a custom folder. Rejected for the two failures above.
- **Binding the folder into `CandidateEligibility`** when it is made, instead of a parameter on each check. Rejected: a check made without it would silently use the default, and the compiler could not say so.
- **Turning off downloads for the whole process** (`IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES`). Rejected for now: it would also stop a Quick Look preview of a cloud file from fetching it, which is a visible change.
- **A new undo refusal for a folder that is gone.** Not needed: `folderUnavailable` already says it.

## Consequences

- Later segments can show Desktop, Documents and custom folders without touching the schema, the executor or undo.
- A custom folder that has moved cannot have its older cleanups undone. To change that, undo must prove a file's place by its name inside the folder, not by its whole path.
- Per-kind archive names, cloud-drive folders, per-folder settings and the privacy texts for Desktop and Documents (`NSDesktopFolderUsageDescription`, `NSDocumentsFolderUsageDescription`) belong to the segment that makes those folders visible.
- Tests that execute against a real log hand the executor a small recorder that puts a run made for a stand-in folder (`ManagedFolder.temporary`) under the log's own Downloads (`CleanupRunStart.recorded(in:)`); a run for any other folder reaches the log untouched. That keeps about a hundred earlier tests as they were, at a price: those tests no longer show that the executor hands the log the plan's own folder. `ManagedFolderExecutorTests`, `ManagedFolderUndoTests` and the undo fixtures give the executor the log itself and do show it. Making every earlier test plan for the log's own folder would remove the recorder.

## Not verified

- That `realpath` on the real Downloads raises no privacy prompt before the welcome. It looks at names and opens nothing, so it should not; this Mac had already answered the prompt.
- That iCloud Desktop and Documents sit at their usual paths on macOS 27 and not inside the Library. It needs an iCloud account with that setting on, and decides nothing until those folders are shown.
- The top-of-a-disk rule for a disk other than the start-up disk is judged by comparing disks; the tests cover `/` and a link to it, not a second mounted disk.
