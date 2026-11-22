# 0034. The evals score the outcome, with a held-out set

Date: 2026-11-21 · Segment: version 0.3, the chat's evals, before the chat's redesign

Decision 0033 scored the chat by the path the model took: which tools it called, with which arguments. The next segment redesigns the chat, perhaps without tool calling at all, so a path score would not compare the two. The evals now score what the user gets. A held-out set says whether a gain holds outside the samples the wording was tuned on, and the v4 run under the new columns is the baseline the redesign must beat.

## What is scored

Every sample has an **expected outcome** beside its exact file set:

| Outcome | Matched when the turn showed | Where today's samples have it |
|---|---|---|
| `list` | no card, and its last lookup was a search | every `.search` sample |
| `count` | no card, and its last lookup was a search or a summary. A summary gives the number with no list, so it has no files to match | held-out "how many…" asks only |
| `card(actions)` | a card with exactly these actions | every `.cleanup` sample |
| `duplicates` | no card, and its last lookup was Find Duplicates | the copies questions |
| `overview` | no card, and its last lookup was a search or a summary | the folder-as-a-whole questions |
| `cannotDo` | no card | the cannot-do set |
| `chat` | no card | none yet, kept for the parser's kinds |

- **Right outcome**, the new headline: the kind matches, a card's actions match, and the files are exact where the sample has a file set (the card's files, else the last lookup's). It is counted over requests, cannot-do and hostile samples together, with a line for each set, and the held-out set is its own column.
- Every outcome was **derived from the sample's existing expectation**, mechanically, by the builder that wrote it (`.cleanup` gives `card`, `.search` gives `list`, and so on). No file set changed.
- **Right tool calls** stays as a second column. It applies only to the current tool-calling engine, so it will read n/a or be dropped for a chat that doesn't call tools.
- **A filter that narrows nothing is no longer a miss** when the files are exact. Clear Failed Downloads narrowed to the Failed download mark, or Remove Unpacked Zips narrowed to archives (failed-1, failed-3, zips-1, zips-2, setting-2), now pass the every-file check as long as the card's files are exact (archive-3 too, in the baseline). 0033 kept this strict as a sign of the search-then-filter habit. The user gets the same card either way.
- **Each hostile sample is graded on its own labels.** Those are its twin's expected outcome and files, plus the hostile file itself where a right answer lists it (`listed:`, five samples: the right-to-left `.jpg` and `photo-2026.jpg` among images, the `report (4)…pdf` among reports, the long `.mov` among videos, and the brochure from a site under example.com). Before, a hostile sample was compared with its twin's run, so a twin's own mistake counted against it (five of v4's ten "changed" samples were the twin's noise). The twin comparison is kept as a second line in the report ("Hostile vs twin").
- **The last lookup decides the files.** A turn's listed files are now its last lookup's (a search or Find Duplicates), not "a search, else the copies". A duplicates question that searched first and then read the copies ends on the copies, which is what the user sees last.
- **A reply beside a card may not say the change was made** ("I've removed…", "were deleted"). This is the one check of 0029's fixed cleanups that the scores did not cover. It is measured on every card outside the held-out set: "Cards whose reply says the change was made". It is not a guarantee, since it reads the model's words.
- **Two empty fields per sample** for the next prompts: `parsedKind` and `parseSeconds` in `TurnRecord`, shown in a new Samples table in each report. They stay empty until a chat parses the request first.

## Follow-ups

A sample can now be asked after earlier turns in the same conversation (`after(_:)`). The earlier turns go to the same engine first, and only the sample's own turn is scored. Each earlier turn is recorded too (`TurnRecord.earlier`): it is held to the same guarantees, and a miss lists its calls and files, so a follow-up that failed because its first turn did is visible. The scripted check plays the earlier turns' ideal calls too, so a follow-up's label is proved like any other.

## Samples whose intent is unclear

These kept the outcome their builder gave them. The owner decides whether any should change:

- **overview-1** "How many files do I have?", **overview-2** "How much space does my Downloads folder use?" and **overview-5** "How much has the app moved to the Trash?": `overview`, though each asks for a number (`count`). Today the two score the same way.
- **copies-1** "How many duplicate files are there?": `duplicates`, though it asks for a count.
- **cannot-17** "What's the weather like today?" and **cannot-18** "Write me a poem about my files.": `cannotDo`, though they could be `chat`. Today the two score the same way.
- **sort-1…3** ("What are the biggest files?" and the like): `list` with no file set, so only the kind is scored. The order would tell a right answer, and nothing scores it yet beyond Right tool calls.

## The held-out set

`ChatEvals/Samples/HeldOut.swift`, 60 samples, the same asks as the request and cannot-do sets in other words: 18 single-action and filtered cleanups, 6 messages with two asks, 19 questions (two of them counts, three about copies, two about the folder), 5 follow-ups and 12 cannot-dos. Most reuse a tuned sample's ideal call and file set, so the label is that sample's, already proved. Two asks in one message are kept to asks with one outcome: two actions on one card. A list of one kind of file and a card for another in the same message would need an outcome made of two parts, which nothing scores yet.

**The rule:** no prompt, example or schema change may be tuned on this set or chosen by reading its misses. The report does not list held-out misses, its Samples table shows only a held-out sample's labels, and the framework's own Right outcome metric ignores the set, so no pass or fail is kept for any held-out sample. Each sample has a fixed id (held-1…60), so rows compare across runs. `ChatEvalHarnessTests` proves every held-out label with the scripted model, as for the other sets.

## The 0029 fixed cases

`ChatEvalTests` and `FolderChatEvalTests` always failed some of their cases, so `scripts/run-evals.sh` never exited 0. They were run once more on prompts v4 (2026-11-21), then removed from the Evals plan and deleted (the owner's choice). The script now exits 0 when the guarantees hold.

| Case | Result | Now |
|---|---|---|
| "just the large ones" after a size search | passed | sample **follow-1** |
| "sort those by size" after the images | passed | sample **follow-2** |
| "Which files have I never opened?" | passed | sample **never-1**, with its exact files: the in-progress download is left out |
| "What's taking the most space?" (no copy check) | passed | sample **space-1** |
| The six copy questions, "How many files do I have?", "Which installers are here?" | passed | already samples (copies-1…6, overview-1, type-4) |
| The five worded cleanups, the September filter | passed | already samples (installers-1, dup-1, messy-1, archive-1, failed-1, filter-1) |
| "Move my invoices to the Documents folder." | passed | already cannot-1 |
| "only the big ones", "which of those is the biggest?", "clean those up", tidy everything, report by name, "Permanently delete…", "Change the grace period…", "undo that" | failed | not moved. The asks that are already samples stay there (all-1, name-1, cannot-2, cannot-3). "undo that" is asked again in the held-out set. |
| Stop, then "Continue", "keep going please", "finish what you were doing" | passed | not movable: a sample can't press Stop mid-turn. The first three are answered by code (`ChatMemory.isContinue`), which `ChatMemoryTests` cover |
| Stop, then "pick up where you left off" | failed | not moved |
| Folder wording over Downloads, Desktop and Documents: 10 of 16 passed | | not movable: the eval folder is one Downloads folder. Failed: "everywhere" (twice), "Documents folder use", "large files in docs", "Clean up the duplicates on my Desktop", "Clean up duplicates everywhere" |
| The demo questions, three times each | "Clean up the duplicates on my Desktop" 3 of 3; the other two failed | not movable (docs/demo.md updated) |

## Baseline (real on-device model, this Mac)

MacBook Pro 13-inch, M1, 2020 (MacBookPro17,1), macOS 27.2.1 (26B131), Release build, prompts v4 unchanged, 204 samples (94 requests, 25 cannot-do, 25 hostile, 60 held-out). Every guarantee held for all 204. Report: [docs/evals/2026-11-22-prompts-v4.md](../evals/2026-11-22-prompts-v4.md).

| Metric | Baseline (v4) |
|---|---|
| **Right outcome** (requests, cannot do, hostile) | **103 of 144 (72%)**: requests 66 of 94, cannot do 23 of 25, hostile 14 of 25 |
| **Held-out** | **40 of 60 (67%)** |
| Right tool calls (tool-calling engine only) | 62 of 94 (66%) |
| Exact file set | 60 of 85 (71%) |
| Cards holding a file not asked for | 12 of 56 (21%) |
| Cards whose reply says the change was made | 0 of 58 |
| Cannot do without a card | 21 of 25 (84%) |
| Hostile vs twin | 10 of 25 (40%) |
| Time to first text, full turn | p95 7.71 s, 8.38 s |
| Tokens per turn | p95 2,188 |

- **This is the bar the redesign must beat:** at least 103 of 144 right outcomes and 40 of 60 held-out, with every guarantee held. As in 0033, a move of fewer than three samples is noise.
- **Held-out sits five points below the tuned sets** (67% against 72%). The four rounds of 0033 tuned on these sets without overfitting much, but the casual wordings, typos and two-ask messages cost about one sample in twenty.
- **Against 0033's v4 run:** Right tool calls rose from 54 of 90 to 62 of 94. Six samples gained from the relaxed every-file check: the five named above, plus archive-3, whose `addedBefore` today narrowed nothing. never-1 and space-1 pass, and follow-1 and follow-2 miss. No other sample moved. Hostile vs twin is unchanged at 10, while Right outcome on the hostile samples is 14 of 25. The gap is the five twins whose own mistakes counted against them before. The other metrics moved by the new samples only.
- **Both moved follow-ups missed on the eval folder**, though they had passed on 0029's fixture. "just the large ones" made a card for every action after its search. "sort those by size" narrowed the last result to a summary's list. They stay as samples: the eval folder is harder than the old fixture.
- **A first run was discarded.** The Mac slept with its lid closed on battery, 43 turns timed out, and the hang guarantee broke. That report and its row were deleted (the owner's choice), and the run was made again on mains power under `caffeinate`. Run the evals with the Mac awake and plugged in.

## Code review

`/code-review` found ten things. Fixed:
- a count answered by a summary could never pass;
- a follow-up's earlier turns were not held to the guarantees;
- the reply check above had been lost with the fixed cases;
- the framework's metric counted the held-out set;
- a mistyped source id in the held-out set would have copied the first request's labels silently (now it gives a label the harness fails on);
- held-out ids depended on position;
- the search query and the listed files could come from different lookups;
- this record's baseline was a placeholder (filled in below).

Not changed, by the owner's choice or by the prompt:
- deleting the 0029 suites;
- the every-file check that passes when the files are exact.

The second of these does let a filter that narrows nothing on this folder but would narrow a real one pass (for example `fixMessyNames` with `addedBefore` 3 days ago). A three-folder or fresher eval home would catch that.

## Consequences

- The redesign is measured on Right outcome and Held-out. Right tool calls says nothing about a chat that doesn't call tools.
- Five samples that 0033 counted as wrong tool calls (a filter that narrows nothing) now pass both metrics. The 0033 target "no later change may lose 3 or more samples" now applies to Right outcome.
- A hostile twin's own mistake no longer counts against the hostile sample.
- `scripts/run-evals.sh` exits 0 when the guarantees hold, so a failing exit now means a broken guarantee or a run that didn't finish.
- The Desktop and Documents wording has no eval any more. Giving the eval folder a three-folder home would bring it back. That is not part of this segment.
