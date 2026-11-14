# 0002. Reading when a file was last opened

Date: 2026-11-14 · Segment: version 0.2, segment 2 (last opened, download source and marks)

## Decision

The last-opened date is read straight from the extended attribute `com.apple.lastuseddate#PS` with `getxattr(2)` and `XATTR_NOFOLLOW`. Launch Services writes this attribute when a user opens a document, and Spotlight's `kMDItemLastUsedDate` is built from it. The value is a 16-byte `timespec`: seconds, then nanoseconds, both little-endian 64-bit integers. `ExtendedAttributeMetadataReader` (FileStoreCore) does the reading, behind the `FileMetadataReading` protocol, so tests and planners can supply dates without touching disk.

- A missing, unreadable or malformed value means "no date", never an error. Malformed means the wrong size, nanoseconds outside 0–999,999,999, or a time at or before 1970.
- A symbolic link is described itself, never followed.
- The file access time (`atime`, `contentAccessDate`) is never used.
- macOS records no last-opened date in this attribute for apps, folders, symbolic links or Finder aliases (opening a link or an alias opens its target). For those, the Last Opened column shows "—" ("Not recorded") instead of "Never" unless a date is there, and they carry no age marks (`FileRecord.recordsLastOpened`). The owner chose this for apps, links and folders; aliases followed in code review, for the same reason as links.
- "No such attribute" (`ENOATTR`) means never opened. Any other failure to read it (a volume without extended attributes, `ENOTSUP`; permission refused; the item gone) means unknown (`FileMetadata.canReadLastOpened`), shown and marked like the kinds above, so a volume that cannot store the date never makes every file Never opened.

## Alternatives

- Spotlight, item by item (`MDItemCopyAttribute(…, kMDItemLastUsedDate)`).
- Spotlight queries (`NSMetadataQuery`).
- The access time (`URLResourceKey.contentAccessDateKey`).
- Launch Services' deprecated item-attribute calls, or private Launch Services interfaces.

## Why

- **It works at once, in any folder.** Spotlight only knows a date after it has indexed the file. It never indexes some folders, such as the temporary folders the tests and the hand-testing script use, and it can be switched off for a volume. The attribute is on the file the moment Launch Services writes it.
- **It is cheap.** One `getxattr` per attribute, with no call to the Spotlight server per file. Reading all three attributes (last opened, where from, quarantine) for 10,000 files adds about 0.6 s to a 0.57 s scan in a Release build on an M1 (docs/benchmarks.md), all off the main actor.
- **The access time is the wrong thing.** Anything that reads a file updates it: a backup, Spotlight's importer, Quick Look, this app's own duplicate hashing. It says nothing about whether the user opened the file.
- **Apps are tracked elsewhere.** I checked on this Mac (macOS 27.2.1): no app in /Applications carries the attribute, while Spotlight reports a last-used date for Xcode.app. Launch Services keeps app launches in its own database, which is not public. Showing "Never" for an app that was launched would be wrong, so apps show "Not recorded".

## Consequences

- Copying a file with Finder or `cp` copies its attributes, so a copy carries the original's last-opened date.
- Whether a particular app records a document it opens itself, through its own Open panel, depends on that app. Opening from Finder always records it. The hand check in this segment confirms that macOS 27 still writes the attribute.
- Folders, apps and links will need another source if a later feature needs their last use; none does yet.
