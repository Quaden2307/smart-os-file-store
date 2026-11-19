# 0021. Chat context, duplicates and the chat's look

Date: 2026-11-19 · Segment: version 0.3, fixes and redesign of the chat bar from segment 1 (0020)

The owner tried the segment 1 chat bar on the fake folder and found four bugs. This record is mostly about the context strategy, the fix for the third; the others follow.

## Context strategy

### What went wrong

The on-device model has 4,096 tokens for everything: instructions, tool definitions, the conversation and the reply. Instructions and tools took 991 (0020). Every finished turn stayed in the transcript in full, tool outputs included, at up to about 300 tokens each. One question that made four lookups (see bug 1) cost about 1,200 tokens, so three such questions filled the context. The engine then dropped the session and asked the user to ask again.

A probe with the real model on this Mac (a scratch program, one lookup of 762 tokens per question): without trimming, the fourth question failed with the private `GenerativeError` 4050000 ("Provided 4,785 tokens, but the maximum allowed is 4,096"). With old tool outputs cut to one line by a history transform, twelve questions went through, while the session's own transcript grew to 13,839 tokens. **Overflow is judged on what the transform sends, not on the transcript.**

### What the model is shown

- **One session per conversation, with a history transform.** `LanguageModelSession.DynamicProfile.historyTransform(_:)` changes what is sent to the model before each call and leaves the session's transcript alone (`ChatHistory.compacted`).
- **The turn in progress goes whole; earlier turns are cut short.** A turn starts at a prompt. In earlier turns each tool output is cut to its first line, which `ToolOutput` writes as a summary built by code: "59 files match, 839 MB in total. The app shows the user the list." The app drew the full card when the result arrived, from `TurnEffects`, so cutting the model's copy changes nothing on screen. The questions, the tool calls and the model's replies stay, so "and which of those are images?" still has something to refer to.
- **A budget, counted before each turn.** The engine counts the instructions, the tools, the earlier turns as they will be shown, and the question, with `SystemLanguageModel.tokenCount(for: some Collection<Transcript.Entry>)`. While that is more than 60% of `contextSize` (`historyShare`), it shows one earlier turn fewer. It starts from one more turn than the last question showed, so a turn takes one or two counts however long the conversation gets (`aLongConversationCountsItsTokensOnceOrTwiceATurn`). The transform reads the number from the turn's `TurnRecorder`. The other 40% (1,638 tokens) is for the turn itself: four lookups at the output cap (about 1,200 tokens with their calls) and a reply. The count is logged with the number of turns shown, and returned as `Turn.tokensBeforeReply`.
- **Overflow is still handled, without asking again.** When a question overflows anyway (`contextSizeExceeded`, or the private error in the tool loop), or fails in a way the engine does not recognise, the same turn asks it again once. It does so in a fresh session seeded with the last two turns, within what is left of the 30-second limit, with the reply cleared first. Beside the answer the reply then carries one quiet line: "This was asked again in a fresh conversation, so earlier messages were set aside." Only a second failure in a row is shown as a message, and that message no longer says "ask once more". Dropping old turns under the budget is silent, as in any chat.
- **The app follows a retried reply.** `ChatModel.show` used to ignore an update shorter than the text on screen, to guard against updates arriving out of order. That would have hidden a retried reply that starts again from empty. Updates are now numbered as the engine hands them over, and an older number is ignored.

### SDK, checked in the Xcode 27.2 interface and doc comments

| Assumed in the plan | The SDK |
|---|---|
| "the framework's history transform if the SDK has it" | `historyTransform(_:)` on `LanguageModelSession.DynamicProfile`, a plain `([Transcript.Entry]) -> [Transcript.Entry]` (not async, so the count is made before the turn and handed over) |
| Count tokens of the conversation | `SystemLanguageModel.tokenCount(for:)` takes instructions, a prompt, tools, a schema or transcript entries. A custom `LanguageModel` has none, so the engine takes a `ContextMeter`; the tests count characters |
| Tools counted separately | The transcript's instructions entry counts its tool definitions too: 280 tokens against 71 for the same instructions alone, in the probe |
| Change a tool output in place | `Transcript.ToolOutput.segments` is settable; `Transcript.Entry` is `@nonexhaustive` |

### Measurements on this Mac

Same Mac as 0020 (MacBook Pro 13-inch, M1, 2020, 8 GB, macOS 27.2.1), Release build, the real on-device model, `ChatMeasurementTests` and `ChatEvalTests` from the Benchmark plan, run one suite after the other.

| What | 0020 | Now |
|---|---|---|
| Instructions | 196 tokens | 196 |
| Tool definitions | 795 (two tools) | 823 (three tools) |
| Together | 24.2% of 4,096 | 24.9% |
| Full turn, 20 questions, no prewarm | p50 3.06 s, p95 4.76 s | p50 3.23 s, p95 3.88 s |
| Full turn, prewarmed | p50 2.19 s, p95 3.20 s | p50 3.35 s, p95 4.37 s |
| One long conversation | full at question 18 (`contextFull`) | 30 questions: 28 answered, 2 refused by the content filter, 0 started over |
| Tokens before the reply in it | (not counted) | 990 at the first question, at most 2,444, 2,403 at the last |

- **The third tool first cost 57 tokens and pushed the total to 25.6%**, over the quarter `ChatMeasurementTests` holds it to. It came back under by shortening four texts: `findDuplicates`' description (33 to 19 tokens), `folderSummary`'s (29 to 25, as `tool-folderSummary-v2`), the limit's guide ("How many to list."; the range of 1 to 100 is still checked in code and given in the answer to a wrong limit) and the site's guide ("Download site."). The evals below ran on the shortened texts.
- **The largest count, 2,444, is the budget at work**: 60% of 4,096 is 2,457. From there each new question pushes the oldest turn out. Before that, each turn added about 90 tokens: the question, the tool call, the one-line stub and the reply.
- **Turn times went up by about 0.2 s at p50.** Each question now first counts the tokens it would show, and the model reads a third tool's definition. Prewarming made no visible difference in this run, as the system kept the model loaded from the previous question. The first run had questions 1 to 4 at 11 to 15 s because the eval suite was asking the same model at the same time. The Benchmark plan now runs the chat suites one after the other (`parallelizable: false`).
- **In the app, on the fake folder** (Debug build, the real model): 13 questions in one conversation, all answered, none started over. The model was shown 989 tokens before the first and 1,951 before the thirteenth, about 90 more a turn, still under the budget.

### Alternatives

- **Roll over to a new session at 70% of the context, seeded with a summary built by code** (the plan's Prompt 4). This was the fallback in case the transform did not count. The probe shows it does, and keeping one session with a transform loses nothing: no summary to write, no "earlier messages" line at every rollover.
- **Cut old outputs to nothing.** The model would then not know what a turn found, and would look it up again for a follow-up that refers to it.
- **Estimate tokens from characters inside the transform.** The ratio varies from 2 characters a token (names and sizes) to 4 (sentences); the model's own count costs one call per turn.
- **Keep asking the user to ask again on overflow.** The owner ruled it out.

## Bug 1: the same line three times

Streaming was not the cause. The engine and the app both replace the reply with each cumulative snapshot, and `aReplyStreamsAndEndsAnswered` pins it. The three "All items: 59 files, 839 MB" lines were three identical lookups in one turn: the card draws a line per lookup, and nothing stopped a repeat. Now each tool works out what it was asked: a search by its checked filter, sort and limit, the summary and the duplicate scan by name. A lookup already covered in the turn (the same one, or the same search listing as many files or more) does not run and is not recorded, and the model reads `output-repeatedLookup-v1`: "You already have this result above. Answer the question now." The hook still counts it against the four-call limit. A search for the same files as an earlier one, in another order or more of them, does run and takes the earlier one's place, so the card has one line per set of files. Beside a folder summary the card leaves out a search with no filter, because the summary's first row says the same.

The table's "Images 2, 38 bytes" was real: `scripts/make-fake-downloads.sh` writes `IMG_4021.jpg` ("holiday photo bytes", 19 bytes) and copies it to `beach.jpg`. Nothing leaked from the tests, which only use temporary folders (`SafetyTests.testFoldersLiveUnderTheTemporaryDirectory`).

## Bug 2: the conversation could not be resized

It had a fixed 240-point height. Its top edge is now a handle: drag it, or use the up and down arrows when it has the keyboard, or VoiceOver's adjust. The height runs from 160 points up to the window's height less 260 (room for a few rows, the status line and the bar). It is kept in `UserDefaults` (`ChatPanelHeight`, 280 by default). A smaller window draws the panel shorter without changing the kept height, and a kept value that is not a number draws the least height. The window's height goes to `ChatModel.panelRoom`, not the window's own state, so resizing redraws only the chat.

## Bug 4: "0 duplicate files"

The model filtered `searchFiles` by the Duplicate mark. That mark only says what the last Tidy Now found (`FileListModel.showDuplicateMarks`), so before one runs it is on no file. Now:

- **A third tool, `findDuplicates`**, with no arguments. Its description (`tool-findDuplicates-v1`): "Reads the files to find exact copies. Use it for any question about duplicates or copies." It calls a function the app hands to `ChatEngine.init(snapshot:findDuplicates:)`, so the chat module still imports nothing of ours. The app reads the Kept list and runs `CleanupPlanners.plan(.findDuplicates, …)` as the Clean Up menu does: the same eligibility and grace period, the session's shared hash cache (trimmed to the listed files first), off the main actor. It hands back `DuplicateScan`, plain rows of each kept file with its copies, how many files could not be read and how many were added in the last hour.
- **The scan stops with the turn.** The app keeps it as a task and cancels it when the reply ends, however it ends: an abandoned reply can go on calling tools (0020), and must not go on reading files. A scan that could not run is taken back, so the model may try it again in the same turn.
- **The wrong path is closed.** The app no longer hands the chat the Duplicate mark (`FolderSnapshot.Mark` has no such case; the exhaustive mapping returns nil for it), so no filter, summary or row can show a stale count beside a real one. A model that asks for the mark anyway gets "Duplicates are found by reading the files, not by a mark: call findDuplicates."
- **Recent files are named, not hidden.** Find Duplicates leaves a file added in the last hour alone, and a file just downloaded twice is the likeliest reason to ask. The tool's output and the card both say how many recent files were not checked, so "no copies" is never the whole answer when they exist.
- Reading files to hash them is code, not the model: the model gets names and counts only. CLAUDE.md keeps "AI that reads file contents" out of scope; this is the existing Find Duplicates, which the owner asked the chat to use.

### Evals for the phrasings

`ChatEvalTests` asks each question in a fresh conversation, over the fixture folder and a fixed scan. With the final texts:

| Question | Lookup | Reply |
|---|---|---|
| How many duplicate files are there? | findDuplicates | There is 1 duplicate file. |
| Do I have any duplicates? | findDuplicates | Yes, there is one duplicate file. |
| Are there copies of the same file? | findDuplicates | Yes, there is one copy of a file. |
| Did I download the same file twice? | findDuplicates | Yes, you downloaded the same file twice. |
| Which files are identical? | findDuplicates | One file is a copy of another. |
| Do I have anything more than once? | findDuplicates | Yes, you have one file with a copy. |
| How many files do I have? (control) | searchFiles | 21 files. |
| What's taking the most space? (control) | folderSummary | The largest files are Xcode.dmg at 900 MB, movie.mov at 700 MB, and backup.tar.gz at 250 MB. |
| Which installers are here? (control) | searchFiles | There are 2 installers: Tool.pkg and Xcode.dmg. |

In the app on the fake folder, "How many duplicate files are there?" and "Did I download the same file twice?" both ran Find Duplicates and drew 6 copies of 3 files: `report.pdf` with four copies, `receipt.pdf` with one, and `IMG_4021.jpg` with `beach.jpg`.

"How many files do I have?" in the app showed the model's habit behind bug 1: it searched for everything, then searched for everything again with a limit of 1. The first version of the repeat check counted the limit as a difference, so the card still had two "All items" lines. A search listing fewer of the same files now counts as a repeat, and one listing more takes the earlier one's place.

## The chat's look

The owner asked for something like ChatGPT or Claude, black and white and minimal. System styles only (`.primary`, `.secondary`, `.quaternary`, `.separator`, `.background`), so Dark Mode follows the system, and no accent colour.

- One centred column, at most 720 points wide. Questions sit in `.quaternary` bubbles on the right. Replies are plain text on the left, with one card of what the lookups found under them, in a thin rounded border.
- A rounded field (corner radius 14: more than half its 32-point height left straight edges), whose border darkens while it has the cursor, with one round button: an up arrow to send, a square to stop while a reply arrives, grey while there is nothing to send. The spinner went.
- Following a reply: the view keeps the bottom in sight while text arrives, until the user scrolls up (`onScrollPhaseChange`: only a scroll the user made, coming to rest away from the bottom, stops it; growing text does not). Asking starts it again. When a reply ends with a long card, the newest question is scrolled to the top, as before, so the sentence stays in view.
- While the model works: three small document symbols shuffle like cards, the front one sliding to the back (`PhaseAnimator`, `.smooth`, 0.55 s a step), crossfading into the reply. With Reduce Motion, one document pulses (`symbolEffect(.pulse)`).

## Consequences

- Three tool definitions are paid for in every turn; the measurement test still holds instructions and tools to a quarter of the context.
- The plan's Prompt 4 asked for "a new session seeded with a summary at 70%". That is covered by the budget and the transform. Prompt 4 still has New Chat and follow-ups to do.
- `ChatEvalTests` are a few fixed cases run on the real model. They are not the Evaluations-framework harness of Prompt 3, which should absorb them.
- A Find Duplicates over large files of the same size can outlast the 30-second turn. The turn then ends as timed out and the scan is cancelled; the Clean Up menu has no such limit.
- Not done: Duplicate marks in the file list after a chat scan, and a Find Duplicates button on the card. Cleanups from the chat are Prompt 2.
