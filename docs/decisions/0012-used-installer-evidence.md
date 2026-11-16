# 0012. Remove Used Installers: what counts as used

Date: 2026-11-15 · Segment: version 0.2, segment 9 (Remove Used Installers)

## Decision

**Which files.** A candidate is a regular file named `.dmg`, `.pkg` or `.zip`, in any letter case, whose scanned type is exactly the one the name gives (`com.apple.disk-image-udif`, `com.apple.installer-package-archive`, `public.zip-archive`). The extension is matched as well as the type: the system also types `.img` as a disk image and `.mpkg` as a package, and neither is an installer here. Bundle-style package folders, `.iso` and `.sparseimage` are not candidates. The shared rules apply before anything is opened: hidden, the archive, downloads in progress, the hour, Kept. A zip is an installer only once its listing shows an app at its top level; one without, or one that cannot be listed, is left out silently, since Remove Unpacked Zips reports those.

**Installed apps** are the `.app` folders at the top level of the application folders (`/Applications` and `~/Applications`; a debug build's `-ApplicationsFolder` replaces both), not links, not hidden. Subfolders such as `Utilities` are not searched.

**Strong**, proposed ticked. Every app the installer holds is installed with exactly the same bundle identifier, at the same or a newer version. For a package:
- every part's receipt (`pkgutil`) is on this Mac at the same or a newer version;
- every app its `PackageInfo` names is installed as above, found by identifier anywhere in the application folders, since an installer can move a bundle;
- a package that installs no app (a driver, a tool) matches on its receipts alone, and its reason names the package.

There is no waiting period after an install (the owner's decision of 2026-11-15): a finished installer can go at once. The installer file still waits the one-hour grace period, as every candidate does.

**Possible**, proposed unticked with the label "Possible match": otherwise, when the installer's file name, cleaned, equals an installed app's name. Cleaning drops the extension, a copy suffix (` (1)`, ` copy`), version parts (`2.1`, `v2.1`, `2.1.0b3`) and platform words (`arm64`, `x86_64`, `universal`, `macos`…), splitting at spaces, `-` and `_`. Names compare without letter case, spaces, `-` or `_`, so `googlechrome.dmg` matches Google Chrome. A version in the name is dropped, never compared.

**Not proposed:** no match; or an app the installer holds is installed only at an older version, or a receipt is older (the installer is an update). An installer that could not be read and whose name matches nothing is listed under Not checked with why: a password, a licence, a timeout, damaged or not an installer, too much to check, a format the reader does not read, or a disk image that is open.

**Versions.** `CFBundleShortVersionString` decides (or the build, for an app that gives no short version, which is also what the reason shows and the executor checks again); `CFBundleVersion` breaks a tie when both can be compared. Dotted whole numbers of any length compare part by part, missing parts as 0, by their digits, so no length overflows. Anything else (`2.1b3`, `1.0 (45)`) cannot be compared and gives no strong match. Package and receipt versions compare the same way.

**Several apps.** All of them must match for a strong match (the owner's decision); otherwise only the name rule applies.

**Right before the move**, besides the shared checks: a disk image must not be attached; the installed app the reason names must still be a real app folder at its path, directly inside one of the executor's own application folders (never the plan's); for a strong match it must still have the same identifier and a version at least the one planned; for a package matched on receipts alone, its receipts must still be there. New skip reasons: `diskImageInUse`, `installedAppMissing(name)`, `installedAppChanged(name)`, and for Not checked, `installerUnreadable(problem)`.

## Alternatives

- **A 24-hour wait after the install:** the request had one; the owner dropped it so a finished installer can be removed straight away.
- **The receipt alone for a package:** a receipt stays after the app is dragged to the Trash, and "used" means the app is on this Mac.
- **The app alone for a package:** ignores the receipts the owner asked for, and could never match a package that installs no app.
- **Any one app of several:** would remove a suite's installer when one of its apps is installed.
- **Matching by type alone:** takes `.img` and `.mpkg`.
- **Comparing the name's version in the name rule:** guessing from a file name; a possible match stays unticked anyway.
- **Searching subfolders of Applications:** more matches, more guesses; the request named the two folders.

## Why

The rules are the owner's. Where they left a choice, each one here proposes less: identifiers match exactly, every app must match, and anything that cannot be compared falls back to a name-only match, which the user must tick.

## Consequences

- An app installed in a subfolder of Applications is never a strong match; its installer can be at most a possible match.
- A suite installed in part keeps its installer, unticked at most.
- An installer put back by undo has a new Date Added and waits an hour before it is proposed again.
- Possible matches start unticked, so running the action again after confirming only the ticked rows proposes them again, unticked. The action is idempotent for what was confirmed, as it is for any row a user unticks in another action.
