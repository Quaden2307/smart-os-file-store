# 0031. What the app has cleaned, over time

Date: 2026-11-21

## Decision

- **Where.** An Insights header at the top of the Activity place, not a tab in Storage: clicking a week's bar filters the run list right below it, which a tab elsewhere could not do without switching places, and Activity is where a user goes to see what the app has done.
- **Data** (`ActivityLog.dailyCleanups`, `CleanupInsights`, tested in `CleanupInsightsTests`): per day, action and folder, the bytes moved to the Trash and the files trashed and tidied (renamed or moved), from the changes that were carried out. A change in a Tidy Now run counts for the action its reason belongs to. An undone change is subtracted on the day it was undone (`undoneAt`). Days are YYYY-MM-DD in the Mac's calendar; a day's week is found from that day's own week start, so a 23- or 25-hour day never moves it.
- **Pruning keeps the totals.** Migration `v9` adds `dailyTotals`. Inside the pruning's own transaction, the changes of the runs about to go are added up per day, action and folder into it, then the runs are removed. All-time numbers are identical before and after (tested), and pruning again adds nothing twice. A change can no longer be undone once its run is pruned, so a rolled-up day never needs lowering later. `changes_attemptedAt` is indexed; reading 10,000 changes takes well under two seconds (tested).
- **The view.** Three headline numbers (moved to the Trash all time, files tidied all time, moved to the Trash this month), a bar chart of the last twelve weeks stacked by cleanup with a switch to the running total, the hovered or selected week's exact figures, and small breakdowns by cleanup and by folder. Palette and rules from docs/design.md (Charts). The wording is "moved to the Trash", never "freed": the app cannot tell whether the Trash was emptied.
- **Empty state.** A new install shows Activity's own empty state, with one sentence and a Tidy now button. No sample data in the app.
- **One source.** The status bar's counter reads the log's `totals` row; the insights read the changes. A test proves they agree after runs, an undo and a pruning.

## Alternatives

- **Counting from `runs.bytesMovedToTrash`.** Rejected: an undo changes the original change, not its run, and a Tidy Now run mixes actions.
- **Rolling up by calendar day in SQL.** Rejected: SQLite's date functions know only UTC and the local time of the process that runs them, not a calendar passed in, so the daylight saving tests could not hold.

## Not verified

- The header on screen in light and dark mode: checked by build and off-screen pictures only.
