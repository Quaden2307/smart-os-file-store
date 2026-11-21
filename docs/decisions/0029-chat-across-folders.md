# 0029. The chat bar works across folders

Date: 2026-11-21

## Decision

- **Scope.** `searchFiles`, `findDuplicates` and `proposeCleanup` take an optional `folder`: nothing for the folder on screen, a managed folder's name, or `"all"`. `FolderScope.resolve` matches the name in code (case and "my", "the", "folder" ignored; a unique start such as "docs" or "desk"), against the folders in the snapshot, which carry their display names. A folder the app does not manage is answered with the folders it does; a folder macOS has not allowed, or that cannot be found, is answered as such and never as empty. The names are untrusted text: quoted and cleaned like file names in every output.
- **`folderSummary` has no folder argument.** The fixed prompt was already 8 tokens under its ceiling (0023); four folder arguments did not fit. The summary is of the folder on screen; `searchFiles` answers totals for another folder or all of them.
- **Snapshot.** `FolderSnapshot` gains `folders` (name, state, which is on screen) and each file its folder's name. The app builds it when a tool asks, from every list the user turned on (`FolderSnapshot(lists:current:activity:)`); a denied folder is `permissionNeeded`, one that cannot be found `unavailable`.
- **Answers.** A search across folders carries `folderTotals` (count and size per folder) and each row its folder; the chat shows the folder beside each file and a subtotal line. Clicking a row of another folder switches the sidebar to it and selects the file.
- **Cleanups.** A card belongs to one folder (`CleanupRequest.folder`), and "What I understood" says which ("in Desktop"). `"all"` makes one card per readable folder, each confirmed on its own (`CleanupCards.show(_ ids:)`: every card of the newest turn is current). An action a folder's rules turn off is never planned there; the app returns it in `CleanupProposal.notOffered` and the reply says so (`output-turnedOff`). Duplicates are found within each folder; asked across folders, the model is told the app cannot compare folders yet (`output-duplicatesPerFolder`).
- **Follow-ups.** The last result's IDs are URLs, unique across folders, and a search inside the last result with no folder searches every folder, so "only the big ones" works after an all-folders answer.
- **Prompts.** `chat` v3 (no longer "Downloads"; "move them between folders" is what it cannot do), `tool-searchFiles` v2, `tool-folderSummary` v3, `tool-findDuplicates` v2 and `tool-proposeCleanup` v2 (both shorter, to make room), and two new outputs. The folder argument has no description: the name says it.
- **The empty chat** suggests "What are the biggest files on my Desktop?".

## Measurements (real on-device model, this Mac, 2026-11-21)

| What | 0023 | Now |
|---|---|---|
| Instructions | 253 tokens | 244 |
| Tool definitions | 1,459 | 1,474 |
| Together | 41.8% of 4,096 | 41.9%: 1,718 of the 1,720 allowed |

Folder evals (`FolderChatEvalTests`, 16 cases over Downloads, Desktop and Documents, Downloads on screen): **7, 9 and 8 of 16** in three runs. Reliable: a named folder for a count or duplicates ("on my Desktop", "in docs"), and no folder meaning the folder on screen. Weak: "everywhere" and "all my folders" (often searched the folder on screen), "Tidy up my desktop", and a cleanup "everywhere" (the model asked for one folder).

Existing evals (`ChatEvalTests`) at the commit before and after, one run each: **6 failing cases before, 8 after** (not counting "Clean up my Desktop.", which left the cannot-do list because Desktop can now be managed). New failures: "Tidy everything" asking for every action, "never opened" leaving out what cannot be told, and three cannot-do requests answered by looking things up first ("Move my invoices to Documents", "Permanently delete…", "undo that"). Two earlier failures now pass. Real-model runs vary between runs, but this is a regression and the plan's bar (the same rate or better) is **not met**. The likeliest cause is the extra argument on three tools and the trimmed wording; fixing it needs either more room in the fixed prompt (the owner's 42% ceiling) or a different tool shape, which is the owner's call.

## Alternatives

- **One snapshot per folder, chosen before the turn.** Rejected: the model decides which folder a question means.
- **A `folder` field inside `FileFilter`.** Rejected: the filter's schema is in two tools, so it would be paid for twice.
- **Raising `fixedPromptShare`.** Not done: the owner set 42% (0023) and the plan said to stay within it.

## Not verified

- The chat in the app against real folders: Apple Intelligence answered in tests, but the window could not be driven tonight.
