# Decision records

One short record per segment for each decision a reader of the code would otherwise have to guess: what was decided, what else was considered, and why. The code says what the app does; these say why it does that and not something else.

## Format

- One file per decision, named `NNNN-short-title.md`: four digits, numbered in order, never renumbered or reused.
- About a page at most, in this shape:

  ```markdown
  # NNNN. Title

  Date: YYYY-MM-DD · Segment: <version and segment>

  ## Decision
  What was decided, in a few sentences.

  ## Alternatives
  What else was considered, one line each.

  ## Why
  The reasons, with measurements where there are any.

  ## Consequences
  Optional: what this means for later work.
  ```

- A record is not edited once its segment is committed. When a decision changes, add a new record that says which one it replaces, and add one line at the top of the old record pointing to the new one.

## Records

- [0001. Grace period and in-use detection](0001-grace-period-and-in-use-check.md)
- [0002. Reading when a file was last opened](0002-reading-last-opened.md)
- [0003. Age marks and the download source](0003-marks-and-download-source.md)
- [0004. Sorting the file list by keys read once](0004-sorting-by-keys.md)
- [0005. One executor for the Trash, rename and move](0005-one-executor-for-trash-rename-and-move.md)
- [0006. The activity log: schema and crash safety](0006-activity-log-schema-and-crash-safety.md)
- [0007. Activity in the main window's sidebar](0007-activity-in-the-main-window.md)
- [0008. Undo, and how it proves it has the same file](0008-how-undo-proves-identity.md)
- [0009. How Kept identifies a file](0009-how-kept-identifies-a-file.md)
- [0010. Clear Failed Downloads, and how the app holds several actions](0010-clear-failed-downloads.md)
- [0011. Remove Unpacked Zips: the matching rule and the zip reader](0011-remove-unpacked-zips.md)
- [0012. Remove Used Installers: what counts as used](0012-used-installer-evidence.md)
- [0013. Reading installers without running or changing them](0013-reading-installers.md)
- [0014. Fix Messy Names: the cleaning rules and name clashes](0014-fix-messy-names.md)
- [0015. Review Near-Duplicates: a review list that always leaves a file](0015-review-near-duplicates.md)
- [0016. Archive Old Downloads and Settings](0016-archive-old-downloads.md)
- [0017. Review Large Downloads and Remove Empty Folders](0017-large-downloads-and-empty-folders.md)
- [0018. Tidy Now: the priority rule and one undo for the whole tidy](0018-tidy-now-priority-and-single-run-undo.md)
- [0019. Hardening version 0.2](0019-hardening-version-0-2.md)
- [0020. The chat bar on the on-device model](0020-chat-bar-on-the-on-device-model.md)
- [0021. Chat context, duplicates and the chat's look](0021-chat-context-and-duplicates.md)
