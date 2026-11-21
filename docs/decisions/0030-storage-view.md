# 0030. The storage view

Date: 2026-11-21

## Decision

A Storage place in the sidebar (Overview section, above Activity) answers "what is taking space, and what could I get back?" for the managed folders. It only reads; nothing is cleaned from it.

- **Numbers in the engine** (`StorageReport`, `ReclaimableSpace`, tested in `StorageReportTests`): total size and count per folder; totals per group with a grouping the caller passes; the ten largest files; and what each cleanup would move to the Trash, from the real planners under the folder's rules, counting only what each preview ticks by default (`CleanupPlan.defaultTickedIDs`), overlap resolved by `TidyNowPlan.resolve` so no file is counted for two actions. Sizes are space on disk (`allocatedSizeInBytes`, else the size); a cloud-only file counts as zero, with a count of its own.
- **Type groups.** The grouping (`FileTypeGroup`) lives in `FileStoreIntelligence`, which imports none of our modules, and the engine cannot import it either. Rather than move it into a third module, `StorageReport.totals(of:by:)` takes the grouping as a function; the app, which imports both, passes `FileTypeGroup(contentType:)`. One grouping, no boundary broken.
- **Charts** (Swift Charts): one stacked horizontal bar per folder split by kind, with a legend that is the table of exact sizes; a "What you can get back" list, one row per cleanup and folder with its bar, size, count and Review…; the ten largest files with thin bars, a click showing the file in its folder. A folder picker: all folders or one. The chart rules are in docs/design.md (Charts) and the palette in `Design.Chart`.
- **Review shows exactly what was counted.** The row's plan is the counted plan itself (narrowed to its default ticks), handed to the normal preview (`CleanupSearchModel.present`). The executor checks every file again on Confirm, as always.
- **Performance.** Totals are computed from the list on screen; what can be got back is planned in the background per folder, once per scan (`StorageModel` keeps the scan generation it planned from), cancelled when a folder leaves. 10,000 files: 133 ms for totals, about 19 s for the planning in a Debug build (docs/benchmarks.md).
- **States.** Loading, nothing to get back, and a folder that cannot be read (the folder's own scan failure, from the shared components).

## Alternatives

- **Moving `FileTypeGroup` into `FileStoreCore`.** The chat module cannot import it, so it would need a third module or a copy.
- **Counting each action's own plan.** Rejected: a duplicate that is also a used installer would be counted twice.
- **A pie or donut chart.** Ruled out by the plan.

## Not done

- **A test that `folderSummary` and the storage totals agree.** No test target imports both modules, and the two count differently on purpose: the chat's summary sums file sizes, the storage view space on disk. Left as it is, and said here.
- Light, dark, Increase Contrast and VoiceOver were not checked on screen: the Mac was locked overnight. Off-screen pictures confirmed the layout.
