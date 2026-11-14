# 0001. Grace period and in-use detection

Date: 2026-11-13 · Segment: version 0.2, segment 1 (groundwork)

## Decision

**Grace period.** An item added to the folder or modified within the last hour is never a candidate for any cleanup action. The rule lives in one type, `CandidateEligibility` (FileStoreCore), which every planner uses and which the executor checks again right before acting, on dates read from disk at that moment. The current time is always a parameter, so tests decide what "now" is.

- Both dates count: Date Added (when the item was put in the folder) and the modification date. A copy, or a file moved in from elsewhere, keeps an old modification date but has a fresh Date Added.
- A missing Date Added (some volumes, such as exFAT, do not record it) leaves the modification date to decide alone. A missing modification date means "not settled". The owner confirmed this.
- At execution, Date Added is read with `getattrlist` rather than taken from the scan. A file put in place of a planned one, with the same name, size, modification date and content, is skipped as "changed since the folder was scanned", which is true, so no new message was needed.
- The same type holds the other rules every action shares: hidden names, downloads still in progress, and the archive folder `Old downloads`, matched in any letter case and whatever kind of item carries the name. Kind and size rules stay with each action. An action with its own rule for downloads in progress (Clear failed downloads) combines the smaller functions itself. Keep marks join this type when they exist.
- Debug builds accept `-GracePeriodSeconds <n>` (a whole number, 0 or more) so hand testing can use files made moments ago. A missing or unusable value falls back to one hour. Release builds ignore it.

**In-use detection.** The engine does not try to tell whether another app has a file open. The grace period and the recheck right before acting remain the protection.

## Alternatives

- Grace period of 10 seconds (version 0.1): long enough for a write to finish, too short for a download that is still being unpacked or looked at for the first time.
- 5 minutes: still inside the time it takes to open, read and act on a fresh download.
- 24 hours: safe, but a duplicate downloaded this morning would not show up until tomorrow.
- Modification date only (version 0.1): misses copies and moved-in files, whose modification date is old.
- In-use detection with libproc (`proc_listpidspath`, or one sweep of every process's open files).

## Why

One hour covers a download finishing, being unpacked and being looked at once, and is short enough that a cleanup the same day still finds it. Keeping the rule in one type means a later action cannot quietly use its own, looser one.

In-use detection was measured on this Mac (MacBook Pro M1, macOS 27.2.1) with a scratch probe, not added to the app:

| Case | Seen by `proc_listpidspath`? |
|---|---|
| A process holding a file open for reading | Yes |
| A file being written | Yes |
| A file memory-mapped, its descriptor closed | Yes |
| A PDF open in Preview (mapped) | Yes |
| A movie open in QuickTime Player | Yes |
| A text file open in TextEdit | **No**: TextEdit reads the file and closes it |

- **Not reliable:** a document visibly open in an app that has read and closed it, which is how most document apps work, looks the same as an unused file. 180 of 486 running processes (those of root and other users) could not be inspected at all. A clear answer would therefore not mean the file is free.
- **Not cheap:** about 87 ms per file (median of five), so 100 files would add almost 9 seconds. A single sweep of open files takes about 20 ms but misses mapped files, so it would miss Preview.
- **Not public:** `libproc.h` in the macOS SDK says of itself: "This header file contains private interfaces to obtain process information. These interfaces are subject to change in future releases."
- **Not needed for safety:** moving a file to the Trash, renaming it or moving it within its volume leaves every open descriptor working, and the Trash keeps the bytes. The real risk, acting on a file still being written, is what the grace period and the recheck guard against.

## Consequences

- Hand testing on freshly made files needs `-GracePeriodSeconds 0`. The fixture script and the test helper date their files two hours back, one second apart in the order made, so the keep rule's "oldest first" still sees the order the files were created in.
- A folder's own modification date does not change when a file deeper inside it changes. Actions that act on folders (unpacked zips, empty folders, Safari `.download` packages) will need to judge a folder by the newest date inside it. That is decided when the first such action is built.
- For rename and move, `NSFileCoordinator` is the public way to cooperate with apps that present a file (TextEdit, Preview). Whether to use it is decided in those segments.
