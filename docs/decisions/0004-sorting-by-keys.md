# 0004. Sorting the file list by keys read once

Date: 2026-11-14 · Segment: version 0.2, segment 2 (last opened, download source and marks)

## Decision

The file list sorts with `FileRecordSorting` (FileStoreCore). It reads each column's key once per record, sorts positions on those keys, and then puts the records in that order. The app's `FileListSort` defines each of the table's six column comparators next to its key: Name and Kind compare text in Finder's order (`localizedStandard`), and the other columns compare values the way `KeyPathComparator(_:)` does, nil first. The columns use those comparators, and a sort uses the keys only when every comparator in the order equals one of them, ignoring direction. `KeyPathComparator` equality covers the comparator inside as well as the key path, which a test checks. Any other order still sorts with `sorted(using:)`.

## Alternatives

- Keep `sorted(using:)` on the main actor.
- Sort off the main actor. `KeyPathComparator` is not `Sendable`, so the sort order cannot be handed to a background task as it is, and the rows would change a moment after each header click.
- Leave the post-scan sort as it was and fix only header clicks.

## Why

Measured with 10,003 records, Release build, MacBook Pro M1 (docs/benchmarks.md): `sorted(using:)` takes 150 ms for the default order, because every comparison reads two key paths through type erasure and moves two large records. The keyed sort takes 22 ms. The app sorts on the main actor after every scan and every click on a column header, so 150 ms was a visible pause with a folder of 10,000 files. Records grew in this segment (last opened and download source), which made the pause longer.

Tests in `FileRecordSortingTests` compare the keyed sort's result with `sorted(using:)` for text, optional and plain values, in both directions, with ties and with two keys, so the order cannot drift from the comparators'.

## Consequences

- A new sortable column needs a comparator and a key in `FileListSort`. Without them it still sorts correctly, only more slowly.
- Sorting by name still compares text in Finder's order, the slowest comparison of all, but each name is read once.
