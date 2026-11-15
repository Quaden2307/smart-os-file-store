# Benchmarks

How long the engine takes on a large folder. Each run of the benchmark adds a row here, copied by hand from its output; numbers from different Macs are not comparable.

## What is measured

`FileStoreCoreTests/BenchmarkTests.swift` builds a temporary folder with 10,000 small files (64 B to 32 KiB, in identical pairs across ten sizes) and three sparse files: two identical 2 GiB files and one 3 GiB file with a size of its own. Sparse files take no disk space and read as zeros through the normal code path. Since version 0.2 segment 2, every small file also carries the attributes a real download has: a download source (`com.apple.metadata:kMDItemWhereFroms`, two addresses) and a quarantine attribute naming the browser. Every other file also has a last-opened date (`com.apple.lastuseddate#PS`).

- **Scan without metadata:** listing the folder into 10,003 records without reading those attributes (`FolderScanner` with a reader that reads nothing). This is the scan as it was before last opened and download sources existed.
- **Scan with metadata:** the scan the app runs, which also reads the three attributes of every item (`FolderScanner.scan`).
- **Marks:** working out Never opened, Unused and Old for every record (`FileMarker.marks`). The app does this off the main actor.
- **Sort:** the table's default order, newest Date Added first, over 10,003 records, both with `sorted(using:)` and with `FileRecordSorting`, which the app uses. The app sorts on the main actor after every scan and every click on a column header (decision 0004).
- **Plan:** Find Duplicates on those records (`DuplicatePlanner.plan`). It hashes the 10,002 files that share a size with another, 4.1 GiB in all, and builds 5,001 groups. The 3 GiB file is never read.
- **Times:** the median of five runs after one warm-up run, with the minimum and maximum in brackets. The files were just written, so the disk cache is warm.
- **Memory:** the test process's physical footprint, sampled while hashing and after each step. Growth is the sampled peak minus the footprint before the first run. The lifetime peak covers the whole process, setup included.

The benchmark is not part of the normal test run; README.md has the command. It checks only that the answers are right (record, source, mark and group counts, and that both sorts agree), never a time.

## Results

| Date | Mac | macOS | Xcode | Build | Commit | Scan without metadata | Scan with metadata | Marks | Sort, `sorted(using:)` | Sort, `FileRecordSorting` | Plan | Peak footprint (growth) | Lifetime peak |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| 2026-11-13 | MacBook Pro 13-inch, M1, 2020 (MacBookPro17,1), 8 GB | 27.2.1 (26B131) | 27.2 (27B52) | Release | `ded25d2` + this segment (committed as *Prepare for version 0.2*) | 645.8 ms (593.5–665.5) | — | — | — | — | 2,204.0 ms (2,026.2–2,471.8) | 78.3 MiB (+56.0 MiB) | 78.3 MiB |
| 2026-11-14 | MacBook Pro 13-inch, M1, 2020 (MacBookPro17,1), 8 GB | 27.2.1 (26B131) | 27.2 (27B52) | Release | `39977b4` + this segment (committed as *Add last opened, download source and marks*) | 571.7 ms (564.8–598.1) | 1,175.3 ms (1,079.8–1,190.8) | 11.6 ms (11.2–16.7) | 149.8 ms (145.4–151.1) | 22.2 ms (21.6–23.0) | 1,944.6 ms (1,928.4–1,969.1) | 108.0 MiB (+82.7 MiB) | 108.0 MiB |

A commit cannot record its own hash, so a row made before its commit names the commit it was built on. The first row's files carried no attributes and its scan read none, so its scan is listed as a scan without metadata.

Reading the three attributes adds about 0.6 s per 10,000 items, about 60 µs per item. The scan runs off the main actor, so the window stays responsive while it does. After a scan of 10,000 files, the main actor does about 25 ms of work: the keyed sort plus filtering. Peak memory grew by about 30 MiB from the first row. The likely reasons are that records now hold their download sources, and that each run now keeps two scans and two sorted copies alive at once.

## Activity log size

`FileStoreCoreTests/ScaleTests.swift` (`tenThousandLoggedChangesStayUnderTenMegabytes`) writes 10,000 changes to a log in a temporary folder the way the executor writes them: a started row, then its result, each in its own transaction handed to the disk (write-ahead mode, `synchronous = FULL`). Every change is a move to the Trash with paths as long as real downloads have and a 32-byte content hash. The test fails if the database, its write-ahead file included, reaches 10 MB at any point; it runs with the normal tests and reports its figures in a `SCALE` line.

| Date | Mac | macOS | Build | Commit | Changes | On disk | Per change | Largest while writing | Time to write |
|---|---|---|---|---|---|---|---|---|---|
| 2026-11-14 | MacBook Pro 13-inch, M1, 2020 (MacBookPro17,1), 8 GB | 27.2.1 (26B131) | Debug | `cf2b349` + this segment (committed as *Add database and activity log*) | 10,000 | 2.91 MB | 290 bytes | 6.56 MB | 2.9 s |

"On disk" is the database after the run's last write, which empties the write-ahead file. "Largest while writing" includes that file, which grows to about 4 MB between checkpoints. Writing takes about 0.15 ms per logged row, two rows per change. Runs older than 90 days are pruned, so the log holds at most 90 days of cleanups.
