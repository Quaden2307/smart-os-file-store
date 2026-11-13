# Changelog

All notable changes to Smart OS File Store are recorded here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow [Semantic Versioning](https://semver.org/).

## [0.1.0] - 2026-11-13

### Added

- A window listing the top level of the Downloads folder: name, kind, size, date added and date modified, sortable by any column, with Quick Look (Space, ⌘Y) and Reveal in Finder (⌥⌘R).
- Find Duplicates (⇧⌘D): finds files with identical content by grouping on size and hashing only files that share a size, with streamed SHA-256 so memory stays flat for files of any size. Keeps the cleanest-named copy, the oldest on a tie. Empty files, folders, packages, symbolic links, hidden files, in-progress downloads and files modified in the last ten seconds are never candidates.
- A preview with a checkbox per duplicate (Space ticks, ⌘A and ⇧⌘A select all or none), a confirmation sheet whose Return and Escape both cancel (⌘⌫ confirms), progress while files move, and a summary of what moved and what did not, with a reason for each.
- A debug-only folder override (`-ScanFolder <path>` or `SMARTOS_SCAN_FOLDER`) and a script that builds a throwaway fixture folder, so cleanups are never tried on real files during development. Release builds ignore the override.
- Continuous integration that builds and tests both the Debug and the Release configuration.

### Safety

- The engine's only removal call is `FileManager.trashItem`; nothing is ever deleted permanently, and a source-scanning test keeps it that way.
- Nothing changes on disk before the user confirms, and no code path skips the preview.
- Every confirmed file is checked again right before it moves: still a regular file directly inside the scanned folder, same size, date and content, kept copy still present with the same content, not locked, hidden or a cloud placeholder. Anything that changed is skipped and reported. Hard links of one file are never treated as duplicates of each other.
- Files added, removed or renamed while a scan, a hash or a cleanup is running are tolerated and reported, never guessed about; cancelling stops work within milliseconds.
- The app is built with Hardened Runtime, and Release builds carry no debugger entitlement, so the bundle can be notarized later. The engine framework is linked statically, because Hardened Runtime refuses an embedded framework signed only to run locally.
- Logs use the unified logging system with file paths marked private and never include file contents.
