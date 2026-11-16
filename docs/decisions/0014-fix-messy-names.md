# 0014. Fix Messy Names: the cleaning rules and name clashes

Date: 2026-11-15 · Segment: version 0.2, segment 10 (Fix Messy Names)

## Decision

**Candidates.** Regular files at the top level that the shared rules allow (not hidden, not the archive, not downloading, past the grace period, not Kept). Folders, packages and links are never renamed.

**Cleaning** (`MessyNameCleaner`) works on the name before the extension, which is what `FileNameCopySuffix` reads as one (`.pdf`, `.tar.gz`; `NSString` treats a "suffix" with a space as no extension). It uses these rules, in this order, and only these:

1. Decode percent-encoding once, when the whole name decodes to valid UTF-8 and the result holds no `/`, no `:` (Finder shows it as `/`), no control character, no bidirectional control (U+061C, U+200E/F, U+202A–E, U+2066–9, which could make `exe.pdf` read as `fdp.exe`) and no further escape. `a%2520b.pdf` is left alone: a second decoding would turn `50%2541 off` (a typed `%41` encoded once) into `50A off`, a name that never existed.
2. Remove a web leftover at the very end, only right after `.` plus 1–10 ASCII letters or digits, with something before the dot. The full list: `?` or `_` followed by `dl=0`, `dl=1`, `raw=1`, `raw=true`, `download=1` or `download=true` (Dropbox, GitHub and the common `download` query), and `@download`. This rule changes the visible extension (`pdf_dl=1` becomes `pdf`); it only takes off what the browser stuck on after the real one.
3. Remove a doubled extension (`.pdf.pdf`, any letter case). The outer one stays exactly as written.
4. Remove a copy suffix through `FileNameCopySuffix.removingCopySuffix`, the function Find Duplicates' `hasCopySuffix` now calls. Only the very end counts: `Chapter (2).pdf` becomes `Chapter.pdf`, while `Chapter (2) notes.pdf` and `Chapter(2).pdf` stay.
5. Collapse runs of spaces, and trim spaces, dots and underscores left at the end of the name before the extension, and at its start only when rule 1 decoded something. Rules 2–4 only remove from the end, so `_draft (1).docx` keeps its underscore.

The rules run again until nothing changes, which makes the cleaner idempotent (`report.pdf (1).pdf` needs rule 3 after rule 4). Every change shortens the name, so the loop ends. A name counts as messy only when rules 1–4 find something; rule 5 alone never renames a file (the owner's choice). After any rule, the extension must read the same as before (except for rule 2), so `notes.txt (1)` and `Version 1.5 (1)` are left alone rather than gaining an extension. A name that would be left empty before the extension, or one no rename may give (`FileNameRules.isAllowedFileName`), is left alone.

**Clashes** (`MessyNamePlanner`). Every name in the scan is taken, whatever its kind, Kept or fresh. So is every name the plan gives out, so no change depends on another being done first. Names are compared as the volume compares them: folded case unless `volumeSupportsCaseSensitiveNames`, and Unicode forms always equal (Swift's string equality, as APFS). When the volume cannot be asked, names are compared ignoring case.
- Clean name free: proposed. When several files want it, the oldest by Date Added (then Date Modified, then name) gets it.
- Taken by a non-empty regular file of the same size and the same SHA-256: nothing is proposed. Find Duplicates handles it. Only these pairs are read, so the action shows a spinner, not a byte count. A file that cannot be read is listed under Not checked.
- Otherwise: `<clean stem> YYYY-MM-DD<ext>`, using Date Added (or Date Modified) in the Mac's time zone, then ` v2`, ` v3`…. A file with no date, or whose dated name would be too long, is listed under Not checked ("The new name can't be used for a file here") instead of vanishing from the preview.

**Execution** needed nothing new: the exclusive rename (`RENAME_EXCL`) skips an item whose destination appeared since the plan, as `destinationExists`, and never tries another name. The preview gained a confirmation for renames ("Rename N files?"). Rename is its default button because a rename replaces nothing and Undo reverses it (the owner's choice; the Trash keeps Cancel as default).

## Alternatives

- Guessing other leftovers (`?v=3`, `?token=…`, any `_key=value`): left out. A real name can end that way, and the owner asked only for listed and tested patterns.
- Decoding `+` as a space: left out, since `+` is common in real names (`C++ notes.pdf`).
- Decoding until nothing is left to decode: rejected after review, since it can invent a name.
- Decoding a leftover written encoded (`file.pdf%3Fdl%3D1`): left out. The extension would change during rule 1.
- Rule 5 on every name: rejected by the owner. It would rename `__init__.py`, `_draft.docx` and `a  b.pdf`.
- Changing letter case, removing dates, versions or words, or truncating a long name: never, by the brief.
- Two identical files wanting one free name: by the brief, the newer gets the date like a different file. Find Duplicates then offers it for the Trash.
- Relying on a name being freed by another rename in the same plan: rejected, since the user may untick that rename.

## Why

Every rule removes something a browser, Finder or a web server added, and nothing a person chose. The checks after each rule keep the extension, so the file opens in the same app afterwards. Comparing names the way the volume does, together with the exclusive rename, means no plan can propose a clash the disk would refuse, and no rename can replace a file.

## Consequences

A name the cleaner refuses stays messy until a later rule handles it; adding a rule or a leftover means a new record. Rule 5 still trims an underscore or dot the person typed right before a copy suffix (`__init__ (1).py` becomes `__init.py`), since it cannot tell it from one left behind (`report_ (1).pdf`). A year in brackets at the end (`Taxes (2024).pdf`) and a last word "copy" (`Ad copy.pdf`) count as copy suffixes, as they always have for Find Duplicates. A hidden file is not in the scan, so its name is not seen as taken. A rename onto it fails safely as `destinationExists`.
