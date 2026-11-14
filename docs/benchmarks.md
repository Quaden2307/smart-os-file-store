# Benchmarks

How long the engine takes on a large folder. Each run of the benchmark adds a row here, copied by hand from its output; numbers from different Macs are not comparable.

## What is measured

`FileStoreCoreTests/BenchmarkTests.swift` builds a temporary folder with 10,000 small files (64 B to 32 KiB, in identical pairs across ten sizes) and three sparse files: two identical 2 GiB files and one 3 GiB file with a size of its own. Sparse files take no disk space and read as zeros through the normal code path.

- **Scan:** listing the folder into 10,003 records (`FolderScanner.scan`).
- **Plan:** Find Duplicates on those records (`DuplicatePlanner.plan`). It hashes the 10,002 files that share a size with another, 4.1 GiB in all, and builds 5,001 groups. The 3 GiB file is never read.
- **Times:** the median of five runs after one warm-up run, with the minimum and maximum in brackets. The files were just written, so the disk cache is warm.
- **Memory:** the test process's physical footprint, sampled while hashing and after each step. Growth is the sampled peak minus the footprint before the first run. The lifetime peak covers the whole process, setup included.

The benchmark is not part of the normal test run; README.md has the command. It checks only that the answers are right (record and group counts), never a time.

## Results

| Date | Mac | macOS | Xcode | Build | Commit | Scan | Plan | Peak footprint (growth) | Lifetime peak |
|---|---|---|---|---|---|---|---|---|---|
| 2026-11-13 | MacBook Pro 13-inch, M1, 2020 (MacBookPro17,1), 8 GB | 27.2.1 (26B131) | 27.2 (27B52) | Release | `ded25d2` + this segment (committed as *Prepare for version 0.2*) | 645.8 ms (593.5–665.5) | 2,204.0 ms (2,026.2–2,471.8) | 78.3 MiB (+56.0 MiB) | 78.3 MiB |

A commit cannot record its own hash, so the first row names the commit it was built on. Later rows record the commit they ran on.
