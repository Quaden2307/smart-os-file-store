# 0018. Tidy Now: the priority rule and one undo for the whole tidy

Date: 2026-11-16 · Segment: version 0.2, segment 14 (the Tidy Now overview)

## Decision

**No new rule, one shared scan.** Tidy Now adds no cleanup rule. `TidyNowPlanner` runs every planner `CleanupPlanners` lists over the records of one scan. The planners that read whole files run one after another in one task, Find Duplicates first, then Review Near-Duplicates, Fix Messy Names and Archive Old Downloads, sharing one `ContentHashCache`; the other five run beside them, each in its own task. Find Duplicates still never reads hashes from the cache, because its hashes alone decide what goes to the Trash; the three after it now read it, since the executor hashes again every file whose change they decide. So no file is read twice in one Tidy Now. Each planner reports its progress and its end; one that throws is reported as failed in its row and the others go on. Cancelling the task stops all of them and throws `.cancelled`; planning writes nothing, so there is nothing to put back.

**The priority rule** (`TidyNowPlan.resolve`, pure). Each file belongs to the highest-ranked change proposing it, and leaves every lower one:

1. Clear failed downloads
2. Remove used installers, strong matches
3. Remove unpacked zips
4. Find duplicates (the copies to remove)
5. Remove empty folders
6. Archive old downloads
7. Fix messy names
8. Review only, never ticked: possible installer matches, then near-duplicates, then large downloads

Around that:

- A change whose file is not directly in the folder, or that the shared rules refuse now (Kept, grace period, hidden or archive name, a download in progress except for Clear Failed Downloads), is dropped whatever its planner said.
- A duplicate group whose kept copy a higher rank trashes (a kept zip that is unpacked, a kept installer) loses its duplicates instead, so one copy always stays; they may then go to a lower action. A group that stays keeps its kept copy out of every lower-ranked Trash change, including Archive's "already archived" Trash and the review lists. The kept copy may still be archived or renamed.
- Two changes never share a destination (compared without case or Unicode form); the lower-ranked one goes.
- A near-duplicate group left with one file goes, as after Keep This File (`CleanupPlan.removing`).

The combined plan's invariants (no item in two changes; nothing Kept, in the grace period or in the archive; no shared destination; every duplicate group left keeps its kept copy and every near-duplicate group two files none of which another action trashes) are tested on 200 generated combinations as well as on each overlapping pair of the fixture.

**Execution and one undo.** `CleanupExecutor.executeTidyNow` runs the ticked changes as one run of the activity log, stored with the action code `tidyNow` (no action's identifier may be that): every move to the Trash in priority order, then every move into the archive, then every rename. Each item is checked by its own action's rules against its own plan's groups, exactly as `execute(plan:)` checks it; the two share one loop. Renames go last so a kept copy is renamed only after its duplicates have been checked against it and trashed. Undo of the run reverses by sequence, so renames come back first, then archive moves, then the Trash. The Activity place calls the run "Tidy Now" and its undo "Undo Tidy Now".

**App.** Tidy Now is the first toolbar item and the first command of the Clean Up menu (⌘T, which no other command uses). The overview lists one row per action that found something (Remove Used Installers' possible matches get their own review row), the review section, failed rows and the quiet "Nothing to Do" list. A row opens the action's own preview in place, in a choosing mode whose Back to Tidy Now (Return or Escape) keeps the ticks and anything Keep This File took out. One Tidy Up asks once with the counts per operation; Cancel is the default (Return and Escape decline, ⌘⌫ or a click goes ahead), as for any Trash confirmation. After the scan, the copies Find Duplicates would remove carry the new Duplicate mark until the next refresh.

## Alternatives

- **A `tidyNow` case of `CleanupAction`.** It would need a planner, a definition and an operation it does not have, and every switch over actions would grow a case that means "several". A run code keeps actions single-purpose.
- **One run per action, undone together.** Undo works on one run, and a crash between runs would leave a tidy half-recorded as two unrelated runs. One run is one row in Activity and one ⌘Z.
- **Letting the planners run fully in parallel.** Find Duplicates and Near-Duplicates would read the same files at once; the chain costs little because the planners after Find Duplicates mostly read from the cache.
- **Trashing a duplicate whose kept copy is trashed by Archive's "already archived" rule.** The bytes would survive in the archive, but the group would lose every copy in the folder. Protecting the kept copy is the safe side; the next Tidy Now archives it.

## Decisions taken without the owner (overnight run)

- Review lists rank below every ticked action, in the order possible installers, near-duplicates, large downloads.
- The kept copy of a duplicate group is protected from every lower-ranked Trash change.
- ⌘T for Tidy Now; the toolbar button has no shortcut of its own so the key is not claimed twice.
- A file both near-duplicate and claimed elsewhere drops its partner from the near-duplicate list too (the group has one file left); the partner can then be in no category this time.
