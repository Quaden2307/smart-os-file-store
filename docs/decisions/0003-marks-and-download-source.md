# 0003. Age marks and the download source

Date: 2026-11-14 · Segment: version 0.2, segment 2 (last opened, download source and marks)

## Decision

**Marks.** `FileMarker.marks(for:now:settings:)` is a pure function that gives a record its marks.

- **Never opened:** no last-opened date, and added more than the unused threshold ago.
- **Unused:** last opened more than the unused threshold ago.
- **Old:** added more than the old threshold ago, opened or not.

The thresholds are 30 and 90 days by default, kept in `UserDefaults` as `CleanupUnusedAfterDays` and `CleanupOldAfterDays` (`CleanupSettings`).

- "More than" is strict, and a day is 24 hours. An item exactly at a threshold is not marked.
- Without a Date Added there is no telling how long an item has been in the folder, so it is never Never opened or Old; it can still be Unused. The owner chose this.
- Folders, apps, symbolic links, hidden items, the archive folder's name and downloads in progress get no age marks.
- A threshold below one day, or one that is not a whole number, falls back to its default, so a mistake never marks everything. A launch argument (`-CleanupUnusedAfterDays 7`) arrives as text and is accepted.
- `FileMark` is an enum whose declaration order is the display order. The table shows any mark as a badge with its title, and the filter lists marks the same way, so adding Installed, Failed download, Duplicate or Kept later changes neither.

**Download source.** The source is the address list browsers store in `com.apple.metadata:kMDItemWhereFroms` and the app named in the quarantine attribute (`flags;time;app;event`).

- The tooltip names the site of the page the file was downloaded from, falling back to the file's own site, with "www." removed, plus the app. The owner chose the page's site.
- Copy Download Source copies the file's own address, the first one recorded, one line per selected row. The owner chose this.
- An entry that is not a web address (Mail stores the sender and subject) gives no site but is still copied.

## Alternatives

- Missing Date Added falls back to the modification date (rejected by the owner: an old file copied in today would be Old).
- Calendar days instead of 24-hour days (a daylight-saving change would move a threshold by an hour either way; 24-hour days keep tests exact).
- Look up the quarantine event in `~/Library/Preferences/com.apple.LaunchServices.QuarantineEventsV2` for the origin address (a private SQLite file, and SQLite is not added until the database segment).
- Tooltip names the file's site (often a download server such as objects.githubusercontent.com, which the user never visited).

## Why

Strict thresholds, the time as a parameter and pure functions make each mark testable at, just under and just over its threshold. Leaving an item unmarked when its age is unknown keeps marks conservative, since later actions (Archive old downloads) will act on them. The two download attributes are what browsers write and what Finder's Get Info shows as "Where from", and both are read without touching the file's contents.
