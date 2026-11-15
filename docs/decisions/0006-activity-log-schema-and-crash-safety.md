# 0006. The activity log: schema and crash safety

Date: 2026-11-14 · Segment: version 0.2, segment 4 (database, activity log and space counter)

## Decision

**One SQLite file, through GRDB.** GRDB 7.12.0 is the app's only dependency, pinned in `project.yml` to the commit its tag points to (`92a554cd0d5e8d67cb18993c6054e73fe42c066c`) and listed on `FileStoreCore` only. Engine files import it as `internal import GRDB`, so the compiler refuses any public declaration that names a GRDB type; the app and the tests never import it. The real log is `~/Library/Application Support/<bundle id>/FileStore.sqlite`. A debug override of the scan folder, valid or not, gets its own database under the temporary directory (`<tmp>/<bundle id>.debug/<hash of the folder's path>/`), and tests use a database in memory. The folder is made 0700 and the file is made empty, 0600, exclusively and through no link, before SQLite opens it; SQLite gives its side files the same permissions. Those calls live in `DiskChange.swift` with the rest.

**Schema (migration `v1`).**

- `runs`: id, action, folderPath, startedAt, finishedAt, state (`running`, `finished`, `cancelled`, `interrupted`), confirmedCount, doneCount, skippedCount, failedCount, bytesMovedToTrash.
- `changes`: id, runID (deleted with its run), sequence, operation, originalPath, resultingPath, sizeInBytes, dateModified, contentHash, reasonCode, reasonDetail, outcome (`started`, `trashed`, `renamed`, `moved`, `skipped`, `failed`), outcomeCode, outcomeDetail, errorDomain, errorCode, errorText, createdFolders (JSON), attemptedAt, undoneAt (empty until undo exists).
- `totals`: one row, bytesMovedToTrash and filesCleaned (items trashed, renamed or moved).
- `maintenance`: one row, lastPrunedAt and lastOpenedAt.

Tables are `STRICT`. Every time is the `Date`'s own `timeIntervalSinceReferenceDate`. Typed values (action, operation, reason, skip reason, failure, run state) are stored as codes written out one by one in `ActivityLogCodes.swift`, never derived from a case's name; the app puts them into words when it shows them. A code this version does not know reads as "unrecognized", not as an error.

**Written before and after each change (the owner's choice).** `CleanupExecutor` cannot be made without a `CleanupRecording`. For each item that passes its checks, a row in the `started` state goes in first, naming any folders a move is about to make; then the last look, the change, and the result, which completes the row, bumps the run's counts and bumps `totals` in one transaction. An item refused by the earlier checks gets its only row right after. The `started` row is written before the last look, not at `beforeChange` as record 0005 planned, so the synced write does not sit in the gap between that look and the change. Writing the row yields a `ChangePermit`, which only the run's journal can make and which every `DiskChange` call on a user's file requires: no row, no change, by the type checker.

**A failed write stops the run.** If the `started` row fails, the file is untouched and no folder is made. If the result fails, the item keeps its true outcome in the returned result and its `started` row stays in the log. Either way nothing after it is touched (`.skipped(.activityLogUnavailable)`), nothing is retried, the run is left open, and `CleanupResult.logFailure` says what happened. If the run cannot be opened in the log at all, nothing on disk is looked at.

**Durability.** Write-ahead mode with `synchronous = FULL`: each commit is synced with `fsync` before the executor goes on, so a row survives the app crashing, being force-quit, or the system crashing. On macOS `fsync` hands the data to the drive but does not make the drive write its own cache; a sudden loss of power can still lose the last rows while the moves they describe stay. Only `F_FULLFSYNC` rules that out, at six times the cost (below), so it is not used. GRDB's write-ahead setup lowers it to NORMAL after every configuration hook, so it is set once the queue exists and a test reads it back. The executor's writes use GRDB's synchronous calls on its own background thread, because the `async` ones are interrupted when the caller's task is cancelled, and a cancelled run must still record the file it just moved.

**Opening.** `PRAGMA quick_check` on the whole file, a database a newer version migrated is refused untouched, one real write (so a read-only file fails here and not mid-cleanup), and any run still `running` is marked `interrupted`. A database that fails is a typed error; except after a failed write (a full disk, another copy of the app), whose file is most likely sound, the app offers to start a fresh log. That renames the file and its side files aside (`FileStore.damaged-<time>.sqlite`, side files first, each rename exclusive, side files put back if the database's own rename fails) and never removes anything. The log's folders are opened one inside the other, never through a link. Cleanup is off while the log is not open, and a failure to read it in the Activity window counts too.

**Pruning.** Once at launch, at most once a day: runs that started more than 90 days ago go, whole, with their changes; then `VACUUM` and a truncating checkpoint. `totals` is a separate table and is never lowered.

## Alternatives

- One row per item, written only after the attempt (the brief's wording): simpler, but a crash in the instant after a move leaves that file out of the log, and a failed write after a move is known only on screen.
- The `started` row at `beforeChange` (record 0005's plan): the same guarantee, with a disk sync inside the gap the last look exists to keep small.
- `synchronous = NORMAL`: faster, but the last seconds of rows can be lost if the Mac loses power, while the moves they describe stay.
- `fullfsync`: the row is on the drive's medium before the move is issued, power loss included; six times the cost per commit, and a 10,000-file run would spend about 13 s on it.
- A rollback journal instead of write-ahead mode: three times slower per commit, and a reader blocks the writer.
- Storing the sentences shown to the user: the engine has no String Catalog, and text frozen at write time ignores a later change of language or wording.
- Dates as text or as Unix seconds: neither gives back the exact `Double`, which the later undo recheck compares.
- `FileManager.createDirectory` and a second privileged file for the log's storage: two places that change the disk again.
- Pinning the package by version tag (`exactVersion`): easier to read and to update, but with the resolved-versions file not committed, a fresh checkout takes whatever commit the tag points to then.

## Why

Measured on this Mac (MacBook Pro M1, macOS 27.2.1, SQLite 3.54.0), 2,000 single-row transactions, the way the log writes:

| Setting | Per commit | Commits per second |
|---|---|---|
| Write-ahead, `synchronous = NORMAL` | 0.027 ms | 36,563 |
| Write-ahead, `synchronous = FULL` (chosen) | 0.098 ms | 10,188 |
| Write-ahead, FULL with `fullfsync` | 0.630 ms | 1,586 |
| Rollback journal, FULL | 0.324 ms | 3,089 |

A changed file costs two commits, about 0.2 ms; in the hand-test run each move to the Trash, its two commits included, took one to two milliseconds. Ten thousand changes, written that way with realistic paths and a content hash each, take 2.91 MB on disk (290 bytes per change), 6.56 MB at the largest with the write-ahead file, in 2.9 s (`ScaleTests`, docs/benchmarks.md).

Read in GRDB 7.12.0's source: typed column subscripts (`row["name"]`) trap on a wrong value, so rows are decoded through `Decodable`, which throws; a bound `Date` is stored as text; `DatabaseMigrator.migrate` does not fail on a migration it does not know, so `hasBeenSuperseded` is checked first.

The static `FileStoreCore` framework archives GRDB's object file, so the app and the test bundle link it through the engine alone. Both builds have no new warnings and no `@preconcurrency` import; a source-scanning test keeps the import inside `ActivityLog*.swift`.

## Consequences

- Undo has what it needs for each change: operation, where the file was and went, size, exact modification date, content hash when the action compared content, and the folders a move made. It will also have to decide what an undone change does to `totals`.
- The app shows a `started` row as interrupted and does not count it in `totals`, since nobody knows whether the file moved.
- A run stopped by a log failure stays `running` until the log is next opened, and shows as interrupted from then on.
- Two copies of the app share one database. A write waits two seconds for the other, then fails and stops its run. A copy that opens the log marks the other's run in progress as interrupted; the run's own last write corrects that.
- `Package.resolved` lives in the generated project, which is not committed, so the commit pin in `project.yml` is what holds GRDB in place. Updating means taking the new release tag's commit and checking what changed.
- A crash leaves at most one row `started`, and for a move it names the folders the move was about to make: like the file, they may or may not exist.
- SQLite itself may change a damaged database while it is being opened (it replays a write-ahead file it finds). What is set aside is the file as that attempt left it.
- A Debug build that scans the real Downloads folder uses the real log, since it changes real files.
- `SafetyTests` now holds `DiskChange.swift` to four calls: the Trash, the exclusive rename, making a folder, and the one exclusive file creation. It also keeps `DiskChange` to three callers and GRDB to the log's files.
- The wording of skip reasons and failures is still the Trash's and Find Duplicates' (record 0005); the Activity window reuses it.
