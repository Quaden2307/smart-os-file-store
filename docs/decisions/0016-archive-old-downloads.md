# 0016. Archive Old Downloads and Settings

Date: 2026-11-16 · Segment: version 0.2, segment 12 (Archive Old Downloads and the Settings window)

## Decision

**What is archived.** Regular files at the top level that the shared rules allow (not hidden, not the archive, not downloading, past the grace period, not Kept) and that `FileMarker` marks Never opened or Unused, with the settings the file list uses (`CleanupSettings`, read from the same defaults at the start of each search). The Old threshold alone archives nothing. Files another action would trash stay candidates; resolving overlap is Tidy Now's job.

**Where it goes.** `.move(to: <folder>/Old downloads, name:)`, under the file's own name; the executor makes the folder on the first move. A name taken in the archive (as the volume compares names) by a different file gets the file's Date Added, `report 2025-01-01.pdf`, then ` v2`, by the helper Fix Messy Names already used (`FileNameRules.datedName`). A name taken by a regular file of the same size and the same SHA-256 means the archive already holds this file: the change is `.moveToTrash` with the reason `alreadyArchived(copyNamed:)`. Archive's definition has a new operation kind, `.archive`, which allows exactly `move` and `moveToTrash`; the executor trashes for this action only when the reason names an archived copy that it finds again, through the folder handle and without following a link, and reads both files again and finds them identical (`CleanupExecutor+ArchivedCopies`). New skip reasons: `archivedCopyMissing`, `archivedCopyNotVerified`.

**Reasons.** `.oldDownload` became `notOpenedSince(Date)` and `neverOpened(downloadedOn:)`, with the date stored in the log row, so Activity says the same as the preview.

**An archive that is not a folder.** The planner looks at the name with `lstat` through the folder's handle. A file, a link or an unreadable folder gives a plan with no changes and `archiveProblem`, which the preview shows as a message. If the archive becomes a file or a link after planning, every move is refused by the existing destination checks before anything changes.

**Metadata.** APFS sets Date Added to "now" when an item moves into another folder (checked by hand). That would make an archived file, and a file put back by undo, look new: lose its Never opened mark and sit in the grace period for an hour. So the executor reads the raw Date Added before a move and sets it back right after it (`DiskChange.setDateAdded`, `setattrlistat` with `FSOPT_NOFOLLOW` and only `ATTR_CMN_ADDEDTIME`), and undo does the same after a move back. A failure there is logged; the move itself has happened. The last-opened date, download source and quarantine are extended attributes, which a rename keeps. The source-scanning safety test now allows exactly this one `setattrlistat` call in `DiskChange.swift` and checks its flags.

**Out of bounds.** A new test runs every planner on the fake folder with the archive filled with old copies of every item, and with those copies' records handed in too: none may name anything inside the archive. It found that Clear Failed Downloads accepted records from inside a subfolder; it now keeps only records directly inside the folder, as the other planners do.

**Settings.** A SwiftUI `Settings` scene (⌘,) with two pickers bound to the `CleanupSettings` keys, and the activity log's path, size (database plus `-wal` and `-shm`) and Reveal in Finder. The main window watches the two keys and works the marks out again at once. The archive folder in the list opens in Finder on double-click; every other row still opens Quick Look.

**Confirmation.** Archiving only moves files and Undo reverses it, so Archive is the Return button, as Rename is. When some files go to the Trash because of an identical archived copy, the sheet says how many and Cancel is the default again, as for every Trash confirmation.

## Alternatives

- **Leave an identical file in place, or archive it under a dated name.** Rejected: the prompt asks for the Trash with a reason. The archived copy holds the same bytes, so nothing is lost, and undo puts it back.
- **A thrown planning error for an unusable archive.** Rejected: the preview already shows plan-level states, and a plan with a problem needs no new error path in the search model.
- **Restrict the executor's moves to the archive folder for this action.** Not done: the move tests use this action's plans for other folders, and every move stays inside the scanned folder anyway.
- **Not restoring Date Added.** Rejected: the prompt asks that undo returns the file exactly as it was, and the grace period and marks read Date Added.
- **Re-check the Never opened or Unused mark right before moving.** Not done: a file opened since the plan is still old by its other dates, the move is reversible, and the executor's recheck is size, modification date and the grace period, as for every action.
- **Keep the debug menu's sample plan of moves.** Removed: the real action now shows the same preview, and the sample's files did not exist.
