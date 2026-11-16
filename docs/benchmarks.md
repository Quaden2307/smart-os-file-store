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
| 2026-11-15 | MacBook Pro 13-inch, M1, 2020 (MacBookPro17,1), 8 GB | 27.2.1 (26B131) | 27.2 (27B52) | Release | `0749095` + this segment (Clear Failed Downloads; marks now include Kept and Failed download) | 617.2 ms (599.2–677.9) | 1,095.9 ms (1,093.1–1,232.8) | 19.6 ms (19.1–54.3) | 160.7 ms (159.7–164.3) | 23.0 ms (22.7–24.5) | 1,998.5 ms (1,975.5–2,041.4) | 110.5 MiB (+84.5 MiB) | 110.7 MiB |
| 2026-11-16 | MacBook Pro 13-inch, M1, 2020 (MacBookPro17,1), 8 GB | 27.2.1 (26B131) | 27.2 (27B52) | Release | `ac083fe` + segment 15 (committed as *Harden version 0.2*) | 672.2 ms (635.0–790.5) | 1,330.6 ms (1,180.3–1,461.7) | 21.5 ms (20.4–34.2) | 180.1 ms (168.4–302.0) | 25.8 ms (25.5–60.5) | 2,250.3 ms (2,043.9–2,953.1) | 126.0 MiB (+99.8 MiB) | 126.0 MiB |

| 2026-11-16 | MacBook Pro 13-inch, M1, 2020 (MacBookPro17,1), 8 GB | 27.2.1 (26B131) | 27.2 (27B52) | Release | same, **50,000 files** (`TEST_RUNNER_SMARTOS_BENCHMARK_FILES=50000`) | 3,137.9 ms (3,046.7–3,667.5) | 5,775.0 ms (5,733.1–6,193.8) | 97.8 ms (96.4–120.7) | 999.0 ms (995.3–1,039.8) | 144.4 ms (143.6–149.1) | 4,766.9 ms (4,721.1–6,254.9) | 594.4 MiB (+508.1 MiB) | 594.4 MiB |

A commit cannot record its own hash, so a row made before its commit names the commit it was built on. The first row's files carried no attributes and its scan read none, so its scan is listed as a scan without metadata.

Reading the three attributes adds about 0.6 s per 10,000 items, about 60 µs per item. The scan runs off the main actor, so the window stays responsive while it does. After a scan of 10,000 files, the main actor does about 25 ms of work: the keyed sort plus filtering. Peak memory grew by about 30 MiB from the first row. The likely reasons are that records now hold their download sources, and that each run now keeps two scans and two sorted copies alive at once.

## Installer scan

`BenchmarkTests.installerScanAtThreeHundredApps` builds a fake Applications folder of 300 apps and a folder of 130 installers: 100 app zips (ditto), 20 packages (`pkgbuild`, no receipt, so possible matches by name) and 10 disk images. Every zip and image holds an installed app at the same version.

- **Index:** reading the 300 apps' `Info.plist` files (`InstalledApps.read`).
- **First search:** Remove Used Installers with an empty cache: every installer read, the 10 images checked, mounted and ejected, two at a time. One run, since a second would find everything cached.
- **Cached search:** the same search with what the first one read stored in the activity log: nothing attached, nothing read but the zips' listings of those that are not installers (none here).
- **Marks:** the Installed marks from the cache (`InstallerPlanner.strongMatches`), as the file list works them out after a scan.
- **Times:** the median of five runs after one warm-up, minimum and maximum in brackets, except the first search.

| Date | Mac | macOS | Build | Commit | Index of 300 apps | First search, 130 installers | Cached search | Marks |
|---|---|---|---|---|---|---|---|---|
| 2026-11-15 | MacBook Pro 13-inch, M1, 2020 (MacBookPro17,1), 8 GB | 27.2.1 (26B131) | Release | `113086a` + this segment (committed as *Add Remove Used Installers*) | 13.8 ms (13.3–14.5) | 4,709.9 ms | 40.9 ms (40.1–41.2) | 27.3 ms (26.4–27.5) |

The first search costs about 0.45 s per disk image, two at a time, for the checker, the mount and the eject; zips and packages take about a millisecond each. Once read, a search of 130 installers takes about 40 ms, so a second search never waits on a disk image.

## Tidy Now

`BenchmarkTests.tidyNowAtTenThousandFiles` plans Tidy Now over one scan of the same 10,000-file folder (5,000 duplicate pairs, two identical 2 GiB sparse files and a unique 3 GiB one): all nine planners, the hashing ones in a chain sharing a fresh content-hash cache each run, the others beside them, then the priority rule. The installer planner gets an empty fake Applications folder. Memory is sampled on every progress report. Times are the median of five runs after one warm-up, minimum and maximum in brackets.

| Date | Mac | macOS | Build | Commit | Records | Tidy Now scan | Peak footprint (growth) |
|---|---|---|---|---|---|---|---|
| 2026-11-16 | MacBook Pro 13-inch, M1, 2020 (MacBookPro17,1), 8 GB | 27.2.1 (26B131) | Release | `8e10ace` + this segment (committed as *Add Tidy Now*) | 10,003 | 4,113.0 ms (3,862.9–5,886.3) | 189.2 MiB (+116.0 MiB) |

Find Duplicates alone takes about 2 s on this folder (above); the rest is the other planners reading the scan and the priority rule. A first version of the priority rule looked up each duplicate's group by scanning every group, and took 13.8 s here; it now uses one lookup table.

## Activity log size

`FileStoreCoreTests/ScaleTests.swift` (`tenThousandLoggedChangesStayUnderTenMegabytes`) writes 10,000 changes to a log in a temporary folder the way the executor writes them: a started row, then its result, each in its own transaction handed to the disk (write-ahead mode, `synchronous = FULL`). Every change is a move to the Trash with paths as long as real downloads have and a 32-byte content hash. The test fails if the database, its write-ahead file included, reaches 10 MB at any point; it runs with the normal tests and reports its figures in a `SCALE` line.

| Date | Mac | macOS | Build | Commit | Changes | On disk | Per change | Largest while writing | Time to write |
|---|---|---|---|---|---|---|---|---|---|
| 2026-11-14 | MacBook Pro 13-inch, M1, 2020 (MacBookPro17,1), 8 GB | 27.2.1 (26B131) | Debug | `cf2b349` + this segment (committed as *Add database and activity log*) | 10,000 | 2.91 MB | 290 bytes | 6.56 MB | 2.9 s |

"On disk" is the database after the run's last write, which empties the write-ahead file. "Largest while writing" includes that file, which grows to about 4 MB between checkpoints. Writing takes about 0.15 ms per logged row, two rows per change. Runs older than 90 days are pruned, so the log holds at most 90 days of cleanups.

## Version 0.2 at 10,000 and 50,000 files

Segment 15 ran the whole benchmark plan twice in Release on the Mac above, at the default 10,000 small files and at 50,000 (`TEST_RUNNER_SMARTOS_BENCHMARK_FILES=50000`, see README.md), on `ac083fe` plus that segment. Segment 1's baseline is the first row of the first table: a scan of 10,003 items in 645.8 ms, Find Duplicates in 2,204.0 ms, 78.3 MiB at the peak.

| Files | Scan with metadata | Tidy Now scan | Peak footprint while planning Tidy Now (growth) | Undo of a 1,000-item run |
|---|---|---|---|---|
| 10,003 | 1,330.6 ms (1,180.3–1,461.7) | 4,238.9 ms (4,101.9–4,538.2) | 189.0 MiB (+100.3 MiB) | 464.3 ms (449.6–484.6) |
| 50,003 | 5,775.0 ms (5,733.1–6,193.8) | 15,073.1 ms (14,557.4–15,152.4) | 764.6 MiB (+515.0 MiB) | 508.4 ms (493.6–531.8) |

- **Database size after 10,000 logged changes:** 3.03 MB on disk (302 bytes per change), 6.63 MB at the largest while writing, written in 2.8 s (ScaleTests, Release, same day).
- **Undo** (`BenchmarkTests.undoOfAThousandItemRun`): plan from the log and the disk, then every file put back from a fake Trash, with the log in a file; the median of three runs.
- **The window.** Scanning, marks and every plan run off the main actor, so the window stays responsive at 50,000 files. The main actor's own work after a scan is the keyed sort, 25.8 ms at 10,000 and 144.4 ms at 50,000, a short pause once per refresh and per click on a column header. Tidy Now's totals are no longer recomputed over every change on each redraw (segment 15). Memory grows about linearly with the number of files, about 10 KiB per file while planning; the benchmark keeps several scans alive at once, the app one.

## Tests and coverage

On 2026-11-16 (segment 15, Debug, the Mac above): **638 tests in 62 suites** pass, the scale suite included and the benchmark left out, and **FileStoreCore has 91.11% line coverage** (11,393 of 12,504 lines). The app target has no tests (0%); it only calls the engine and shows results. The command:

```bash
xcodebuild -scheme SmartOSFileStore -destination 'platform=macOS' -derivedDataPath build test -enableCodeCoverage YES -resultBundlePath /tmp/coverage.xcresult
xcrun xccov view --report --only-targets /tmp/coverage.xcresult
```

