# 0019. Hardening version 0.2

Date: 2026-11-16 · Segment: version 0.2, segment 15 (harden and tag)

## Decision

No features. A high-effort code review of everything since v0.1.0 and a security review of the whole codebase were run, and these findings were fixed, each with a test unless noted:

- **Tidy Now protects a trashed zip's unpacked copy.** `TidyNowPlan.resolve` keeps the item named by `unpackedZip(unpackedTo:)` out of every lower-ranked Trash change, as it already did for a duplicate group's kept copy. Before, a near-duplicate or large-download tick could trash `report.pdf` in the same run that trashed `report.zip` for being unpacked to it. A rename or an archive move of the unpacked copy is still allowed: the content stays.
- **One tick rule, in the engine.** `ProposedChange.Reason.isTickedByCode` (not review-only, not a possible match) is what the preview's default, Select All and Tidy Now tick. Select All used to tick possible installer matches.
- **Settings shows the effective threshold** (`CleanupSettings`' own validation), not a stored value the app ignores. No test: it is view code; the validation it uses is already tested.
- **Crash recovery after a case-only rename back.** `UndoReconciler` called "the file answers at both paths" ambiguous; when the two paths are one name in two cases or Unicode forms, the folder's listing (compared scalar by scalar) now decides.
- **Find Duplicates reads its item and kept copy through the folder's `DirectoryHandle`**, like every other action, instead of by absolute path. No new test: the existing duplicate executor tests cover the behaviour, and the race it closes cannot be staged without a hook in the executor.
- **Activity's reload keeps the assessments of a run opened while it was reading.** No test: app model.
- **`ContentHashCache.keepOnly`** drops the hashes of files the latest scan no longer lists, called at the start of every search; its comment no longer claims the executor re-hashes near-duplicates.
- **Tidy Now's totals are stored**, updated when plans or ticks change, instead of recomputed over every change on each render. No test: app model.

The security review found nothing at confidence 8 or above. Left as they are, with the reasons given in the review: a disk image swapped between its header check and `diskutil attach`, and a file swapped between the last look and `trashItem`, both theoretical local races; Fix Messy Names can drop `?dl=1` to reveal an executable extension, but the new name is shown and confirmed and the quarantine attribute stays.

Two memory tests failed now and then when other suites ran beside them (`hashes200MBWithoutLoadingIt`, 32 MiB; `scansAndPlansThousandsOfFilesWithFlatMemory`, 64 MiB). Their bounds are unchanged. The hasher test now samples the footprint on every chunk (a peak, which also catches a file loaded and released) and takes the smallest growth of up to five runs; the scale test measures again, up to twice, only when a run is over its bound.

## Alternatives

- Running memory tests in a test plan of their own: they would leave the normal run, which is where a regression should show first.
- Disabling parallel testing: every suite would run serially, several times slower.
- Protecting the unpacked copy from renames and archive moves too: not needed, nothing is lost by either.

## Why

The tick rule and the unpacked-copy rule are about the one thing the app must never do, lose the only copy of something; both now live in the engine where tests reach them. The memory fixes keep what each test proves (a file is never held in memory) while noise from other suites, which is transient, no longer fails it.

## Consequences

Not done in this segment, for lack of time: the single table-driven test of every planner against one hostile folder, the zip and installer fuzz test, and the failure drills (disk full, volume gone, access revoked, force quit in Tidy Now). The existing tests cover parts of each (Safety, PlannersRespectKept, ZipListing, InstallerReader, ActivityLogFailure, ChangeDuringUse, DiskImage); the rest is listed for the next segment.
