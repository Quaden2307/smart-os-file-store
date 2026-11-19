# 0020. The chat bar on the on-device model

Date: 2026-11-18 · Segment: version 0.3, segment 1 (a chat bar that answers questions about Downloads)

## Decision

### The chat module imports none of the app's own code

`FileStoreIntelligence` is a static framework with no dependencies in `project.yml`. It imports Foundation, FoundationModels and three system modules, and nothing of ours, so it cannot name the executor, `DiskChange`, the activity log or GRDB. That is how "the model can never change a file" is a fact of the build:

- The app copies what the chat may know into plain rows (`FolderSnapshot`: name, type, size, Date Added, last opened, download site, marks, and the log's total moved to the Trash) each time a tool asks. The mapping is field for field in `FolderSnapshot+Records.swift`, and the mark mapping is an exhaustive switch, so a new `FileMark` does not compile until the chat knows it.
- `DIAGNOSE_MISSING_TARGET_DEPENDENCIES: YES_ERROR` is set for every target. Xcode puts every built module in one products folder, so an `import` of a module a target does not depend on can otherwise compile. Checked both ways with a deliberate `import FileStoreIntelligence` in an engine file: without the setting the build succeeded; with it the build fails with "is missing a dependency on". An `import FileStoreCore` in the chat module fails either way today (GRDB's module map is not on its search path), which is luck, not a guard.
- `BoundaryTests` fails when a source of the module imports anything off its allow-list (any form of import, any subfolder), when `nm` finds a `FileStoreCore` or `GRDB` symbol in the built archive, when `project.yml` gives the target a dependency or loses the setting, when `PrivateCloudCompute` is named, or when the engine or the app imports FoundationModels. `SafetyTests` scans the new folder too, so its bans on file-changing calls, forced paths and GRDB cover it.

The owner chose this over splitting the engine (below). `plans/apple-intelligence.md` says the module "can read scan results and call the planners"; from here on it reads rows the app hands it and, when a later tool needs a plan, calls a function the app hands it. See Consequences.

### What the SDK offers, where it differs from the plan's names

Read in the Xcode 27.2 SDK's `FoundationModels.swiftinterface` and the doc comments in its `.swiftdoc`.

| The plan says | The SDK has |
|---|---|
| A fake that conforms to the framework's model protocol, if practical | `protocol LanguageModel` with an `Executor: LanguageModelExecutor`, both macOS 27. The executor streams events (`.response(.appendText)`, `.toolCalls(.toolCall(…appendArguments))`) into a channel. Practical: `ScriptedModel` in the test target. No protocol of ours was needed |
| "The session's tool-call hook" | `onToolCall`, only on a session built from a `LanguageModelSession.Profile` (`init(profile:history:)`), not on the plain initialisers |
| Guardrail refusals, context overflow | `LanguageModelSession.GenerationError` is deprecated in 27. The errors are `LanguageModelError` (`guardrailViolation`, `refusal`, `contextSizeExceeded`, `unsupportedLanguageOrLocale`, `timeout`, …), `LanguageModelSession.ToolCallError`, `SystemLanguageModel.Error.assetsUnavailable` and, for a tool name that does not exist, `GeneratedContent.ParsingError` |
| Greedy sampling | `samplingMode: .greedy`; `sampling` is deprecated |
| A limit on tool calls | None in the SDK. Ours, in the hook |
| Availability states | `SystemLanguageModel.Availability`: `available`, or `unavailable` with `deviceNotEligible`, `appleIntelligenceNotEnabled`, `modelNotReady`. Language support is separate (`supportsLocale`). The reason enum is not frozen, so an unknown reason reads as "not ready yet" |
| Date filters | `Date` is not `@Generable`; dates travel as text |
| On-device only | The same framework ships `PrivateCloudComputeLanguageModel`. The engine names `SystemLanguageModel` and nothing else |

### How the session behaves (probed with the scripted model, since the docs do not say)

- `onToolCall` runs before the tool. When it throws, that tool does not run and the turn ends with `ToolCallError` wrapping our error. So both guards live in the hook.
- A call to a tool that is not registered never reaches the hook or any tool: the session throws `ParsingError` ("unrecognized name").
- Several calls made in one round run at the same time, so the call budget is counted under a lock.
- A guide such as `.anyOf` is not checked when arguments arrive (a custom model can send any string), and a missing required argument ends the turn with `ToolCallError`. So every argument is optional and checked in code.
- Cancelling the task that reads the stream ends the stream at once and without an error, even while the model keeps going. The session is not responding afterwards, takes the next question, and forgets the cancelled turn; late text from the abandoned round does not leak into the next reply. (The real model's abandoned reply can still call tools, though: see Measurements.)
- An error thrown by the model reaches the caller unchanged. With `.revertTranscript` the transcript goes back to before the turn.
- A new session can be seeded with an earlier transcript (`history:`).
- With a custom model, a snapshot reaches the stream's reader two events late. `ScriptedModel` follows text with two empty fragments so partial text arrives before a pause.

### Tools, output and effects

- Two read-only tools: `searchFiles` (the shared `FileFilter`, a sort, a limit) and `folderSummary`. Counting, summing, sorting and dates are code.
- `FileFilter` is one `@Generable` struct, every field optional. Type group, mark and sort are text with allowed values and dates are `YYYY-MM-DD` or `N days ago`, all read by `validated`, which rejects inverted ranges, negative sizes, unknown values and unreadable days with a message that names the field and the fix. A rejected call is answered with that message, not thrown, so the model can correct itself within the turn. What a model may write for "not asked" narrows nothing: `neverOpened: false` and `largerThanMB: 0`. A bare site name ("github") matches a whole part of a site's name. Days are read and written in the Gregorian calendar whatever calendar the Mac shows.
- `ToolOutput` is the only place that writes text for the model: counts, a total, at most 8 names with size and days since added, capped at 600 characters, about 300 tokens (names are dropped from the end to fit). A name or site is cleaned of control, format, private-use and unassigned characters and of the two delimiter characters, cut to 60 characters, and wrapped in `⟦ ⟧`, which the instructions call data.
- Each tool writes its full typed result to the turn's `TurnEffects`. Under the model's sentence the app draws, from that, one line per lookup saying what was looked up in the app's own words ("Images · 100 MB or more: 2 files, 838.9 MB") and the files of the last lookup. A lookup that is not what the question meant is visible there. The model's sentence is shown without the data marks it tends to copy. The total is worded "moved to the Trash", as everywhere else in the app.
- Templates (`chat-v1` and the two tool descriptions) are in `PromptLibrary.swift`, each with a version; `PromptLibraryTests` pins each one's SHA-256. The short `@Guide` texts stay beside their fields, where the macro needs literals.

### Guards and outcomes

- At most 4 tool calls a turn and only registered tools, both in the hook. A 30-second limit per turn, raced against the stream; the turn returns at the limit even when the model ignores cancellation.
- A turn ends as `answered`, `stopped`, `timedOut`, `toolLimitReached`, `refused`, `contextFull`, `unavailable(reason)` or `failed`; the app shows one plain sentence for each and never an alert.
- After a full context, or a failure the engine does not recognise, the next turn starts a fresh session. After Stop or the time limit a new session is made from the history before that turn, so the conversation is remembered and the abandoned reply cannot reach it.
- On a new day the session is replaced by one whose instructions name that day, with the same history, so an app left open overnight does not tell the model that today is yesterday.
- A question can be asked only while the file list is settled: a lookup during the first scan, or after a failed one, would count an empty list and show that as fact.
- The conversation is held in memory by the app's `ChatModel` and the session; nothing typed is logged. The engine logs outcome kinds, counts, durations and the type of an error, never its text.

### Measurements on this Mac

MacBook Pro 13-inch, M1, 2020 (MacBookPro17,1), 8 GB, macOS 27.2.1 (26B131), Release build, the real on-device model, a fixed folder of 71 rows (`ChatMeasurementTests`; README has the command).

| What | Result |
|---|---|
| `contextSize` | 4,096 tokens (the plan hoped for 8,192) |
| Instructions | 196 tokens |
| Both tool definitions | 795 tokens: about 190 that any tools cost, about 540 for `searchFiles` (most of it the filter's schema), about 60 for `folderSummary` |
| Instructions and tools together | 991 tokens, 24.2% of the context |
| A tool's output | 174 tokens for a usual search (404 characters), 234 for the summary (525), 265 for the longest search the cap allows (554) |
| Time to first text, 20 questions, no prewarm | p50 2.97 s, p95 4.04 s |
| Full turn, no prewarm | p50 3.06 s, p95 4.76 s |
| Time to first text, prewarmed | p50 2.14 s, p95 2.79 s |
| Full turn, prewarmed | p50 2.19 s, p95 3.20 s |
| Stop, one second into a reply | returned in 0.3 ms as `stopped` |
| Overflow | one conversation of distinct questions was full at turn 18 (`contextFull`); the next turn started fresh and was answered |

- Each question ran in a fresh conversation, first without prewarming and then with a two-second head start. "No prewarm" is not a cold model: after the first question the system keeps it loaded (the first took 6.3 s). All 20 ended `answered`, 18 with one lookup and 2 with two.
- The first text arrives when the answer does: the lookup comes first and the reply is a sentence, so streaming shows almost nothing early. The panel says "Looking…" meanwhile.
- **Over budget at first, so shortened**, as the brief requires. The first cut was 187 + 864 tokens, 25.7%. Shorter `@Guide` texts brought it to 22.7%; the two worked examples and the "cannot" sentence below then cost 63 tokens back. There are 33 tokens of room under the quarter, and a tool that takes the filter pays for the filter's schema again (about 450 tokens), which Prompt 2 will have to deal with.
- **The first output cap was too generous.** 1,000 characters came to 395 tokens, because names, sizes and dates cost about two characters a token. The cap is 600 characters; a line gives "added 3 days ago" where it gave a date (14 tokens for a date), and no longer the download site.
- **A full context shows up two ways.** A plain session throws `LanguageModelError.contextSizeExceeded` ("Content contains 4114 tokens…"). In the tool loop the same condition arrived as `GenerativeFunctionsFoundation.GenerativeError`, a private type ("Retained context (4231 tokens) leaves no room to generate…"), NSError domain `com.apple.GenerativeFunctionsFoundation.GenerativeError`, code 4050000, and every later turn failed the same way. The engine knows it by that domain and code. Because that can change with macOS, any failure it does not recognise also starts a fresh conversation, so the chat can never be stuck; the user is told the conversation started again.
- **After Stop, the old session is not reused.** In the scripted tests a cancelled session was clean. With the real model, one run's next question ended at the tool-call limit: the abandoned reply was still running behind the session and its calls counted against the new turn. A new session made from the history before the stopped turn shares nothing with the old one; Stop at seven different moments was then followed by a correct answer every time.
- **A guardrail false positive, and its fix.** With a sort value named `oldest` on offer, "What is the oldest file here?" was refused every time ("Response may contain sensitive or unsafe content") before any tool ran; "What was added first?" was not. With the value named `earliest` both are answered. The sort is `earliest`.
- **Wording that changed what the model does**, found by asking 18 questions over rows shaped like the fake folder and reading each lookup:
  - `minSizeMB` and `maxSizeMB` with short guides were read backwards ("bigger than 100 MB" set the maximum, and the model then repeated the search until the limit). Named `largerThanMB` and `smallerThanMB`, they were used correctly.
  - Asked to delete or move a file, the model searched until the limit. With "You cannot delete, move, rename, open or change files… call no tool and say plainly that you can only look things up here" in the instructions it answers at once, with no lookup.
  - With "use only the arguments the question needs" it often searched with no filter at all and answered from that. "Put what the question asks for in filter" and two short examples in the tool's description gave the right lookup first time for 15 of the 18.
  - Still wrong, and left for the evals (Prompt 3): "in the last 30 days" filtered on today, "PDFs" counted every document, and some replies list file names although told not to.

## Alternatives

- **Split the engine into a planning target and an executing target** (83 files moved, about 100 `internal` to `package` changes, six code moves, the safety tests reworked). The chat module would see `FileRecord` and eight planners, but still not `CleanupPlanners`, where the Kept list is applied, nor the installer search, which makes a private folder through `DiskChange`. Rejected by the owner for the smaller cut.
- **Mark the executor's public surface `@_spi`.** "Cannot name without opting in" is weaker than "cannot import".
- **A fake one level up, behind a protocol of ours.** Not needed: the framework's own protocol works, so the real session and tool loop run in tests.
- **The call budget inside the tools.** Works without relying on the hook's order, but the hook is what the brief asked for and the probe shows it runs first; `ChatEngineTests` fails if a later SDK changes that.
- **`AsyncStream` out of the engine.** Cancelling its reader does not cancel the producer without extra wiring, and the reader never receives the final outcome. A plain `async` function with a text callback is the shape `CleanupExecutor.execute` already has.
- **Generated enums for type group, mark and sort.** The framework would reject a wrong value by ending the turn; text checked in code answers with the allowed values.
- **Only absolute dates.** The on-device model is poor at date arithmetic; `N days ago` needs none.
- **Apple's `SpotlightSearchTool`.** It searches the index, not the scanned folder, and knows none of the app's marks.

## Why

The model is small and can be steered by what it reads. Everything that must be right is therefore outside it: the boundary is the build's, the limits are code's, and what the user is shown as fact is computed and drawn by the app. A wrong answer can then only be a wrong sentence above a correct list.

## Consequences

- `plans/apple-intelligence.md` was written for a module that imports the planners. With this boundary its later prompts read differently:
  - Prompt 2: the code that narrows a plan to the chosen files and merges by the Tidy Now rules belongs in `FileStoreCore`, tested there against the planners called directly; `proposeCleanup` reaches it through a function the app hands in, and the action list is passed in from the action registry. The plan object stays with the app, as the prompt already says.
  - Prompt 5: `ContentExtractor` takes a file's address and facts, not a `FileRecord`.
  - Prompt 8: `NameFromContentPlanner` lives in `FileStoreCore`, as the add-cleanup-action skill expects, and takes insights as plain values.
- ⌘K is the chat bar's. Keep This File moved to ⇧⌘K, in the main window and the preview.
- The chat field is the app's first text field. Edit > Undo is "undo the newest cleanup", so it is off while the field has the cursor; ⌘Z does not undo typing there. While a cleanup search is running, Escape cancels that search first, as before.
- Every tool definition is paid for in every turn. The room left is in Measurements; Prompt 2 measures again with `proposeCleanup` (`ChatEngine.fixedPromptTokens`).
- The deployment target is macOS 27, which the custom-model protocol and the profile hook need. CI's `xcode-27` image runs macOS 27.0.1 with Xcode 27.2.
- Not done here: New Chat, trimming old tool outputs and rolling a long conversation over before it overflows (Prompt 4); evals (Prompt 3).
