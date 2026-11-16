# 0015. Review Near-Duplicates: a review list that always leaves a file

Date: 2026-11-16 · Segment: version 0.2, segment 11 (Review Near-Duplicates)

## Decision

**What matches.** Regular files at the top level that the shared rules allow (not hidden, not the archive, not downloading, past the grace period, not Kept) whose cleaned names (`MessyNameCleaner`, segment 10) are equal, extension included, compared as the volume compares names (any letter case unless the volume is case-sensitive). Their content must differ. Files with identical content are duplicates, Find Duplicates' business: a group shows one file per distinct content (the one Find Duplicates would keep: cleanest name, then oldest) and notes how many identical copies it has; a name group with one distinct content is no group. Hard links count as one file. Folders, packages and links take no part.

**Reading.** Files are grouped by cleaned name first; only files in a name group of two or more are hashed, one at a time, each at most once. A session-long `ContentHashCache`, held by the app's search model, remembers every hash read, keyed by URL and valid only for the same size, modification date and disk identity (volume and file number). Review Near-Duplicates reads it and adds to it; Find Duplicates only adds to it. Hashing is one file at a time behind a spinner, as Fix Messy Names does.

**The plan.** `CleanupPlan.nearDuplicateGroups` holds the groups; each file shown is a `.moveToTrash` change with the reason `nearDuplicate(sameNameAs:)` ("Same name as notes.txt, different content"). `Reason.isReviewOnly` is true for it: the preview ticks none of these, Select All skips them (and is hidden for this plan), and no automatic flow, Tidy Now included, may tick them. No file is marked as the one to keep.

**A group always keeps a file.** The preview will not tick the last unticked file of a group and says why under each group. The executor enforces it whatever it is sent: when a confirmation names every file of a group, the newest by modification date (then the first by name) is skipped with `lastInGroup`; and each file moves only if another file of its group, not being moved in this run, is still in the folder as the plan saw it (a regular file of the same size and modification date). A file that changed since the plan (size, date, grace period) stays, as for every action. No content hash is written to the log, since the content is not read again before the move; undo proves the file by its disk ID.

**Keep This File and idempotence.** Keep This File takes the file out of its group; a group left with one file goes, as a replan would show it (a Kept file takes no part). A group whose remaining files are all ticked is unticked, so the user decides again rather than the executor keeping one back. The action is not idempotent in the usual sense, by design: files the user left unticked, and the rest of a group of three or more, are shown again next time, because they still share a name and differ. What a run moved is never proposed again.

**The preview.** Title "Similar names, different content", command Review Near-Duplicates (⇧⌘R). Each row shows the size, Date Added, Date Modified and Last Opened, with "Newest" (latest Date Modified) and "Largest" as facts when not every file shares them. Quick Look works on every row; with two rows selected, Space shows them side by side (two Quick Look views in a sheet). The side-by-side view works in every preview, since the sheet is shared and Space on two rows had no meaning before.

## Alternatives

- **Make `DuplicateGroup.kept` optional.** Rejected: every duplicate path, the executor's kept-copy checks and many tests read `kept`, and one hash per group does not fit files that differ. A separate group type keeps Find Duplicates' guarantee untouched.
- **Refuse the whole confirmation when it names every file of a group.** Rejected: the prompt asks that a crafted confirmation leaves one; skipping one file and moving the rest is the smallest refusal.
- **Let Find Duplicates read the cache too.** Rejected for now: its hashes decide what goes to the Trash, so it keeps reading the files themselves. Near-duplicate hashes only decide which files are shown together, and the executor rechecks size and date before moving.
- **Hash only files that share a size within a name group.** Not done: the prompt says to hash files in name groups of two or more, and the cache already avoids a second read.
- **Shortcut ⇧⌘N.** Rejected: it is Finder's New Folder, which this app will need when it replaces Finder.
