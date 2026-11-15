# 0009. How Kept identifies a file

Date: 2026-11-15 · Segment: version 0.2, segment 6 (Keep this file)

## Decision

**A Kept entry names a file by its volume's UUID and its number there (the inode).** `PersistentFileIdentity` holds both. The scanner reads the number with `lstat`, exactly as the executor reads it right before a change, so the two always agree. Keep This File reads the number again when it marks a file, so a file saved as a new copy since the scan is marked as the file at its place now. The volume's UUID is read once per scan, run or load, through a URL made for the purpose: no cached value is used, and a linked folder is followed. The device number `lstat` also reports is not used, because it can change when a disk is mounted again. The path stands in only where the volume has no UUID or does not keep numbers across mounts (`volumeSupportsPersistentIDs`). That cannot happen for Downloads on macOS 26, which is always on APFS.

**The matching rule** is written once, in `KeptItems.contains`, and the store's Stop Keeping deletes by the same rule:
- An item with an identity is Kept when an entry has that identity, or when an entry made without one has its path. A different file that later takes the name has another number, so it is not Kept.
- An item without an identity is Kept when any entry was made at its path. When the app cannot tell which file it is, it protects what sits where a Kept item was.

**Where it is applied.**
- **Planners:** `CandidateEligibility.allows` refuses a Kept record (`Refusal.kept`, checked last), so every planner that filters with it excludes Kept items. The app plans only through `CleanupPlanners`, whose Kept list is a required argument read fresh from the log before each search; if the list cannot be read, nothing is planned.
- **Find Duplicates:** it lets a Kept copy take part, but only as the copy its group keeps. One Kept copy is kept whatever its name. With several, the usual rule chooses among them. None of them is proposed. A group whose copies are all Kept is left out. A Kept file that cannot be read is left out entirely, rather than listed as unchecked.
- **Executor:** the Kept check happens inside `recordIntent`, in the same database transaction that writes the change's started row. Without that row there is no permit, and no change on disk. So the check comes after every other check, including hashing a large file, nothing can be marked Kept between the check and the row, and no code path can skip it. It is one indexed query: `KeptItems.contains`, written in SQL as `keptMatch`.
  - A Kept item gets no started row, only its result row: skipped as `markedKept`.
  - A log that cannot be read stops the run, as a failed write does.
  - The check uses the identity just read, not the scan's, so a Kept file put in the place of a scanned one is also refused.
  - For an item without an identity, it compares both the plan's spelling of the path and the path it acts on (`<folder>/<name>`).

**Dropping entries.** Each time the list is loaded (after every scan and when the log opens), an entry is dropped only when the system says its item is gone. The rows are read first and looked up on disk with no lock held; the database is written only when an entry is to be dropped.
- An identity entry on the scanned folder's volume is dropped when `fsgetpath` returns `ENOENT` for its number.
- A path-only entry inside the scanned folder is dropped when `lstat` finds nothing there.
- Nothing is dropped for an entry on another volume, or for one the system could not answer about, or while the folder itself cannot be reached.

A Kept file moved into a subfolder, out of the folder, or to the Trash still exists, so it stays Kept, and it is Kept again when it comes back.

**Storage.** The list is table `keptItems` (migration `v3`) in the activity log's database. So a debug override's database has its own list, pruning never touches it, and "Start a Fresh Log" sets it aside with the rest of the old database. The messages offering a fresh log now say so.

**Undo is not affected** (the owner's decision). Kept stops cleanups from proposing a file. Undo only reverses a recorded change, and the file stays Kept afterwards.

## Alternatives

- **The path alone:** a rename loses the mark, and a new file with the old name inherits it. That is the opposite of what was asked.
- **`URLResourceKey.fileResourceIdentifierKey`:** it does not survive a restart.
- **`fileIdentifierKey`:** the same number on APFS. For a hard link on HFS+ it can differ from `lstat`'s, which the executor reads.
- **Document IDs (`documentIdentifierKey`):** these survive a safe save, but only after the app sets a tracking flag on the user's file. That would be a change on disk outside the engine's three operations.
- **Checking only the plan's snapshot of the list at execution:** this misses a file marked Kept after the plan was made.
- **Dropping an entry whenever its file is not in the listing:** a move into a subfolder would lose the mark.

## Why

Probed on this Mac (macOS 27.2.1), in a temporary folder on the APFS Data volume, from an unprivileged process:

| Step | Result |
|---|---|
| Volume UUID and `volumeSupportsPersistentIDs` of the folder | A UUID; `true` |
| `fsgetpath(fsid, inode)` for a file just made | Its path |
| The same after renaming it, and after moving it into a subfolder | The new path each time; the inode is unchanged |
| The same after removing the file | `ENOENT` |
| `fsgetpath` for a folder's number | Its path |
| `FileManager.replaceItemAt` (a safe save) onto the file | New inode at the path; the old number gives `ENOENT` |
| An atomic write (`Data.write(options: .atomic)`) | New inode at the path |

## Consequences

- **Editing a Kept file in an app that saves safely or atomically gives it a new number.** That includes most document apps. The mark is then lost, and the old entry is dropped at the next load. To the app this looks exactly like "a different file took the name", which must not be Kept. Downloads are rarely edited in place; the owner can mark the file again.
- **Kept marks do not survive a move to another Mac or a restore from a backup.** Downloads then sits on a volume with a new UUID, and its files have new numbers. Entries for another volume are never dropped, since an external disk may only be unplugged, so they stay until Stop Keeping All. They are counted in its confirmation.
- **Keeping a duplicate from the preview changes the next search.** That copy becomes the one kept, so the next Find Duplicates proposes the original instead.
- A planner added later is covered by `PlannersRespectKeptTests` once it is listed in `CleanupPlanners`. That test also fails until it is added to its list of planned actions.
