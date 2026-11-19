# 0023. Cleanups from the chat bar

Date: 2026-11-19 · Segment: version 0.3, segment 2 (Prompt 2 of plans/apple-intelligence.md)

The chat could only look things up. Now it can prepare a cleanup: the model calls one new tool, the app plans with its own planners and shows a card in the conversation, and files change only from the user's Confirm.

## Decisions

### One tool, and the plan never leaves the app

- **`proposeCleanup`** takes a list of actions, the filter of `searchFiles`, and two settings. It plans nothing itself. It checks the arguments in code, turns the filter into file IDs from the snapshot, and calls a function the app handed in (`ProposeCleanup`). The app plans, keeps the plan, and hands back rows: per action a count, the bytes that would go to the Trash and how many changes are ticked, plus up to five names.
- **The boundary is unchanged.** `FileStoreIntelligence` still imports none of our modules. It cannot name a plan, the executor or the log. A card is known to it by a UUID the model never sees. `BoundaryTests` passes untouched.
- **The executor is called from one place**: `TidyNowModel.execute`, reached from the card's confirmation sheet or from the Tidy Now preview the card's Review opens.
- **The action list comes from the registry.** The app hands the tool `CleanupAction.allCases` that have a planner, by identifier, and the tool builds its schema when the app runs. A new action is offered with no change in the chat module.
- **Settings offered: `archiveAfterDays` and `largeFileMB`.** They stand in for `unusedAfterDays` and `largeDownloadMegabytes` for one plan. `oldAfterDays` is not offered: it only sets the Old mark and moves no planner.
- **`"all"` is every action**, checked in code. The model then has nine names fewer to write.

### Planning is Tidy Now's, with a list of actions and a set of files

- `TidyNowPlanner` takes `actions` (every action by default) and `plan(only:)`. Each plan keeps only its changes to the named files (`CleanupPlan.removing`), then `TidyNowPlan.resolve` merges as for any Tidy Now: a file once, removal before archive before rename, the kept copy and the unpacked item protected.
- **Narrowing comes before merging.** A file outside the request is never changed and protects nothing: a zip that is not in the request does not shield the folder it was unpacked to from another action in the request.
- **Kept, the grace period and the archive are respected because the planners and `resolve` already do it.** `ChatCleanupPlanTests` proves it for plans made this way, whole and narrowed.
- Default ticks are each action's own (`isTickedByCode`). Large downloads, near-duplicates and possible installer matches stay unticked.

### The card

- **A card is a `TidyNowModel` that starts in review of a plan that is already there.** Review presents the existing Tidy Now sheet on that model, so ticks changed there are the card's ticks. Confirm asks the one question Tidy Now asks (`TidyNowConfirmationSheet`), the owner's choice over running at once.
- **"What I understood" is built by the app from the checked request** (`CleanupRequest.understood`): the actions by their menu names, the filter in the words the lookup card uses, and a setting when one was given. Nothing in it comes from the model's sentence.
- **Which card may be confirmed is one small value type**, `CleanupCards`: the newest card is the current one; a card is ready, out of date or confirmed; only a current, ready card can be reviewed or confirmed; a card that was run never goes back to waiting.
- **Out of date** means one of its files is gone, or has another size or modification date, judged against the list as last read (`CleanupPlan.staleChangeIDs`, the same comparison the executor makes right before a change); or the copy a duplicate group keeps is; or the user marked one of its files Keep since; or a newer card took its place. The list is read again when the app becomes active again (back from Finder, not after a sheet) while a card waits, and whenever the user refreshes. There is no folder watching. What only the executor can know (an app uninstalled since, a folder a zip was unpacked to) does not put a card out of date: the executor skips those files and the summary says so.
- **Review and Confirm wait for a reply to finish.** A reply still arriving could put a newer card in this one's place while its sheet is open.
- **A card is shown for a turn that planned one and then ran out of lookups or time.** The plan was made and is the app's, whatever the model went on to do.
- **"Nothing to clean up" is never said when an action could not be checked** and the others found nothing: the model is told the cleanup could not be prepared.
- **Refresh plans the same request again** with no question to the model, over the list as it is now.
- **After Confirm the card is the run's summary.** Its Undo follows the activity log's record of the run, so an undo from Edit > Undo or from Activity shows on the card as "Undone". Only the newest cleanup is offered for undo there, as in Edit > Undo.
- **No card** for a call with unknown or missing actions, a setting out of range, an argument of the wrong kind, a filter that matches no file, or planners that found nothing. Each is answered with a sentence the model can act on.

### The activity log

- Migration `v6` adds `runs.origin` (text, NULL for the app, `chat`). `CleanupRunStart`, `executeTidyNow(origin:)` and `ActivityRun.origin` carry it. Activity shows "From Chat" beside the run.
- **A chat run is stored as a Tidy Now run**, also when it has one action, because it is planned, merged and carried out by the same code. Activity and Undo therefore call it "Tidy Now".

## The token budget

The owner decided to raise the ceiling for the fixed prompt (instructions and tool definitions, read again in every turn) from a quarter of the context to 42%, measured first.

| What | 0022 | Now |
|---|---|---|
| Instructions | 196 tokens | 253 |
| Tool definitions | 828 | 1,459 |
| Together | 25.0% of 4,096 | 41.8%: 1,712 of the 1,720 allowed |

- `proposeCleanup` costs 631 tokens, most of it its own copy of the filter's schema, as 0020 expected.
- The ceiling is `ChatEngine.fixedPromptShare` (0.42), held by `ChatMeasurementTests.theFixedPromptStaysWithinItsShareOfTheContext`, now a test of its own that runs in two seconds.
- `historyShare` stays at 60%. The model is therefore shown fewer earlier turns: about 745 tokens of them, where it had about 1,430. The app's note (0022) still carries the rest.
- **There are 8 tokens left.** A third copy of the filter (`reviseCleanup` in Prompt 4) does not fit.

## SDK differences and behaviour found

| Plan or expectation | In the SDK, or measured |
|---|---|
| An enum generated from the registry | `@Generable` and `@Guide(.anyOf:)` need their values at compile time. A runtime list needs `DynamicGenerationSchema(name:anyOf:)` inside `DynamicGenerationSchema(arrayOf:minimumElements:maximumElements:)`, turned into a `GenerationSchema(root:dependencies:)` (which throws), and a tool that declares `parameters` itself with hand-read `Arguments` (`ConvertibleFromGeneratedContent`). A `@Generable` type nests in it with `DynamicGenerationSchema(type: FileFilter.self)` |
| An array argument | **Needs `maximumElements`.** Without it the model went on writing actions until the 30-second limit ("Tidy up my whole Downloads folder." timed out with no tool call) |
| Reply wording in the instructions | "Say a preview is ready, and which part was left out" in the instructions leaked into the answer to every question ("A preview is ready. The request left out a sorting preference."). It is now the last line of the tool's own output (`output-cleanupReply-v1`), read only after a cleanup was planned |
| A cleanup hint in the last-result note | "To clean them up, call proposeCleanup…" in the note made the model prepare a cleanup after questions it could not do ("Move my invoices to Documents"). The note now only says what to answer to "undo" |

## Evals on the real on-device model

`ChatEvalTests`, fixture folder, greedy sampling. Seven rounds of wording; the kept texts are `chat-v2`, `tool-proposeCleanup-v1`, `note-lastResult-v2`. The stand-in for the app's planning "finds" every file it is asked about, so counts in these replies are not real plans.

| Asked | What happened | Right? |
|---|---|---|
| The nine questions of 0021 and 0022, six ways of asking about duplicates | The same lookups as before, no card | Yes |
| "only the big ones", "sort those by size", "Continue" after Stop | As in 0022 | Yes |
| "which of those is the biggest?" | One search, then more calls until the limit of four | **No.** It passed in 0022 |
| "Fix the messy file names." | `fixMessyNames`, every file | Yes |
| "Tidy up my whole Downloads folder." | Five actions, every file | Yes |
| "Remove the installers I've already used." | A search first, then `removeUsedInstallers` narrowed to installers | Yes |
| "Get rid of duplicate files." | The lookup, then `findDuplicates` | Yes |
| "Archive my old downloads." | A search, then `archiveOldDownloads` narrowed to the Old mark | Yes |
| "Clear out the failed downloads." | A search, then the wrong action (`removeUnpackedZips`) | **No** |
| "Archive the files I downloaded before September and never opened." | `archiveOldDownloads`, but "added on or after 1 September" | **No.** The card says "added since 1 Sep 2026" |
| "clean those up" after "Which installers are here?" | Two searches, then two actions (`findDuplicates`, `removeUsedInstallers`) narrowed to one of the two installers | **No** |
| "pick up where you left off" after Stop | The stopped question answered, then a Large Downloads card nobody asked for | **No** |
| "Move my invoices to the Documents folder.", "Permanently delete report.pdf…", "Change the grace period…", "undo that" | A short answer, no card | Yes |
| "Clean up my Desktop." | A card for Downloads, every action | **No** |

- **"Keep going please" and "finish what you were doing" are now answered by code**, like "Continue" (`ChatMemory.isContinue`, which also drops "please"). Left to the model, they went the way "pick up where you left off" still does.
- **Seven of the thirteen eval tests pass and six fail**, each on one of the rows marked No. Before this segment all nine passed. The eval suite is not part of the normal test run.
- A wrong card changes nothing on disk, and "What I understood" shows what it is. The misses above are for Prompt 3, which builds the eval harness and tunes with at most four rounds.
- Two copies of the app, started before this session, were open during the evals. 0022 saw model time-outs under that condition.

## Measurements on this Mac

Same Mac, Release build, the real on-device model, `ChatMeasurementTests`.

| What | 0022 | Now |
|---|---|---|
| Full turn, 20 questions, no prewarm | p50 3.24 s, p95 4.43 s | p50 4.42 s, p95 7.84 s |
| Full turn, prewarmed | p50 3.41 s, p95 4.54 s | p50 4.84 s, p95 7.90 s |
| Stop | 0.8 ms | 16 ms; the next question was refused by the content filter |
| One conversation of 30 questions | 29 answered, 1 refused | 30 answered, 0 started over |
| Tokens before the reply in it | 995 first, at most 2,455 | 1,683 first, at most 2,455, 2,418 last (the budget is 2,457) |

- **A turn takes about 1.2 s longer**: the model reads 690 more tokens before every reply.
- One of the 20 questions ("What are my newest downloads?") hit the tool-call limit in both runs.
- **In the app, on a fresh fake folder** (Debug build, the real model): "Fix the messy file names." drew a card, "Fix Messy Names", Messy Names 9 items, "Ticked: Rename 9. Nothing changes until you confirm." Review opened the Tidy Now preview with that one category. Confirm asked "Rename 9?", and Tidy Up renamed the nine files. The card became "9 done, 0 skipped, 0 failed" with Undo; the log held one run, `tidyNow`, origin `chat`. Undo put the nine names back and the card said "Undone". Asked again, then one of its files changed and the list refreshed: the card said "Out of date" with only Refresh, and Refresh made it ready again.

## Where the tests sit

The app target has no test target, so the tests sit on both sides of the function the app hands in.

- **`FileStoreIntelligenceTests`, scripted model** (`ProposeCleanupTests`): the tool passes actions, files and settings through unchanged, for each action and for several; a filter narrows to exactly the files a search finds; the checked request behind "What I understood"; Refresh's files; no card for each bad call, for nothing found and for a request with no tool call; the output's first line, counts, five cleaned names and cap; one card per turn; a second request replacing the card; and the card rules (`CleanupCards`).
- **`FileStoreCoreTests`** (`ChatCleanupPlanTests`), on the shared fake folder: each action's plan equals its planner called directly; several equal `resolve` of the planners' plans; narrowing; removal before rename and archive before rename among chosen actions; no kept, grace-period or archived file; which changes went stale; a confirmed plan logged as the chat's, then undone; migration `v6`.
- Not tested by a unit test: the app's glue (`ChatModel`), which was run by hand as above.

## Alternatives

- **`searchFiles` with an optional action list**, so the filter is paid for once (about 28% of the context). No separate tool to choose, but the lookups tuned in 0021 and 0022 would have had to be evaluated again, and Prompts 3 and 4 name `proposeCleanup`. Offered to the owner, who chose to raise the ceiling.
- **`proposeCleanup` with no filter, working on the last search** (about 30%). A filtered cleanup would need two tool calls in a row.
- **One-click Confirm on the card.** Offered to the owner, who chose the confirmation sheet.
- **A guard that refuses `proposeCleanup` after a lookup in the same turn.** It would have stopped the cards after questions, and also three of the six cleanups that worked, where the model searched first.
- **A list of cleanup words checked in code before the tool may run.** English only, and a gate on wording is not something code can guarantee.
- **Watching the folder for the card.** Out of scope until the owner asks.

## Consequences

- The fixed prompt is at 41.8% and a turn is about 1.2 s slower.
- The scripted context in `twentyQuestionsInARowAllFitWithoutStartingOver` grew from 3,000 to 3,300 characters, by the 270 the instructions grew.
- A card's buttons can be below the fold of the conversation: a reply still scrolls to its question, as in 0021.
- A chat cleanup of one action reads "Tidy Now" in Activity and in Undo.
- A narrowed plan keeps its planner's list of skipped items, which can name files outside the request.
- `/code-review` found ten things; all were fixed in this segment (Keep after a card was planned, a failed planner read as a clean folder, plannings cancelling each other, Review during a reply, installer facts not kept, the kept copy in staleness, a plan dropped at the lookup limit, a rescan after every sheet, a lookup table per plan, and an eval assertion that had been dropped and is back). `/security-review` found nothing above its bar.
- Not done: `reviseCleanup`, New Chat, the selection as context (Prompt 4), and the eval harness (Prompt 3).
