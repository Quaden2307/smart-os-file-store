# 0022. Chat memory, "no open recorded" and the Apple Intelligence label

Date: 2026-11-19 · Segment: version 0.3, chat memory, the never-opened answer and the AI indicator

The owner used the chat bar from 0021 and reported three things. After "Stopped.", typing "Continue" got "You can only look things up here." "Which files have I never opened?" answered 50 files, 839 MB, which looked like every file. And the bar did not say it was Apple Intelligence. This record is mostly about the first.

## Memory

### What went wrong

- **A stopped question was forgotten on purpose.** After Stop or the time limit, the engine makes a new session from the transcript before that turn, because the abandoned reply can keep running behind the old session and calling tools (0020). So the stopped question was nowhere. "Continue" then referred to nothing, and the only fallback sentence in the instructions is "you can only look things up here". A test pinned it: "The stopped question is not part of what the model remembers."
- **All memory lived in the framework's transcript.** A turn that was refused, hit the tool limit, or failed or overflowed twice left nothing behind. A turn dropped by the token budget left no trace either.
- **The model had no handle on the last result.** An earlier turn is shown as its tool call and a one-line stub. "Those" or "the big ones" meant rebuilding the old filter from old JSON, and a duplicate scan or a folder summary has no filter to rebuild.

### Decision

**The app keeps the memory, in code** (`ChatMemory`, held by the `ChatEngine` actor):

- a line per answered turn, built by code: the question cut to 60 characters and cleaned, and what its last lookup found ("3 files, 8.6 MB"). The last 20 are kept;
- the **last result**: the tool, the filter in words, the sort, the IDs of every file found (not only the ones listed) and their total size. A search gives its matches, a duplicate scan the kept files and their copies, a summary its largest files. It is taken from the turns whose card is on screen: answered ones, and stopped ones that had finished a lookup. A search that found nothing leaves it as it was, so "the ones over 500 MB then" still has files to look in;
- the **pending question** of a turn that was stopped or ran out of time. It waits until a question is answered. If another question comes in between and fails, it is dropped too, so a later "try again" cannot bring back an older question than the one meant; the stopped question itself may fail and still be continued.

**The model gets a short note in front of the question**, never a list and never an ID. For example:

```
[Notes from the app, not from the user]
Earlier in this chat: "Which images are here?": 3 files, 8.6 MB
This request was stopped before it was answered: "Which files are over 500 MB?". If the user asks to continue, answer it now.
Last result: 5 files, 1.99 GB (50 MB or more, sorted newest). "Those", "them" and "the big ones" mean these files: to narrow or sort them, call searchFiles with "mark":"lastResult" in filter. By size means "sort":"largest". Big means "largerThanMB":500. If asked to clean them up, delete them or undo something, answer only: "I can only look things up here. The Clean Up menu cleans up, and Edit > Undo undoes a cleanup."
[The user's message]
only the big ones
```

- The note has up to three parts, each a versioned template in `PromptLibrary` (`note-earlier`, `note-stopped`, `note-lastResult`, wrapped by `note`): the turns the model is no longer shown (the newest that fit 300 characters), a stopped request, and the last result.
- It is put in front of the **current** prompt by the history transform (`ChatHistory.compacted(_:keepingEarlierTurns:note:)`). The session's transcript keeps the bare question, so an old note is never shown again and never has to be trimmed.
- The guidance for follow-ups is in the note, not in the instructions, so a first question costs no more than before.
- Text in the note that the model chose (a name it searched for, a site) is between the data marks and cleaned like any text from the disk: the model may have copied it from a file name. A filter description over 160 characters is replaced by "several filters", not cut, so a mark is never cut in half.
- **The session is still one per conversation with a transform** (0021). When it is lost (a second failure or overflow in a row), the next one starts with an empty transcript as before, but the note still carries the summary and the last result. That is the rebuild from memory.

**Follow-ups search inside the last result.** A filter with `"mark":"lastResult"` makes `searchFiles` look only at the stored IDs (`FileQuery.withinIDs`), then filter and sort as usual. With no sort given it keeps the order the list was in. The card says "In the last result · 500 MB or more". With nothing to refer to, the model is told "There is no last result yet."

**"Big" is the app's number.** The note names the size set for Review Large Downloads (the app hands the engine a small function that reads `CleanupSettings`), so "only the big ones" means the same as the app's own list and is not a number the model makes up.

**"Continue" is answered by code.** After a stopped or timed-out question, a message that is only "continue", "go on", "keep going", "resume", "carry on" or "try again" (any case, end punctuation ignored) asks the stopped question again in its place. Any other wording goes to the model with the stopped request in its note. Once any question is answered, nothing is pending.

**"Clean those up" and "undo that" are declined** (the owner's choice for this segment): the chat still only looks things up. The note gives the model the sentence to say, and what "those" means is kept for the next question. Cleanups from the chat are Prompt 2 of the plan.

### The token budget

- The engine counts before every turn with the framework's `tokenCount(for:)` (`ContextMeter`, 0021) and shows fewer earlier turns until the count is inside 60% of the context. The count now includes the note.
- **It counts with the note at its longest**: the summary as the lines repeated to exactly its 300 characters, which no real summary exceeds. The fewer turns are shown, the more of them the note has a line for, so counting with the real note made the count grow as turns dropped out, and a turn then took three counts. With the longest note the size does not depend on how many turns are shown, and a turn still takes one or two counts (`aLongConversationCountsItsTokensOnceOrTwiceATurn`). `Turn.tokensBeforeReply` is therefore "at most": early in a conversation it is over by the unused part of the summary, up to about 80 tokens.
- **Instructions and tools stay within a quarter of the context, with nothing to spare: 1,024 of 1,024 tokens.** See the next section.

### Why "last result" is a value of `mark`

The first version gave `searchFiles` its own argument, `inLastResult: Bool`. It cost 27 tokens in every turn and put instructions and tools at 1,046, over the 1,024 that `ChatMeasurementTests` allows. Getting back under meant shortening what the 0021 evals were run on: dropping one of the tool's two examples (11 tokens) and five argument guides (11 more). With those cuts the real model stopped using the filter on a first question: "Which images are here?" and "Which installers are here?" searched for everything. So the cuts were undone, and "lastResult" became a seventh value in the `mark` guide's list, which costs 5 tokens. It is not a mark: `FileFilter.validated` turns it into `withinIDs` before marks are read, and a comment on the field says why it rides there. The price is that a follow-up cannot also filter by a real mark in the same call.

### Evals, on the real on-device model

`ChatEvalTests`, fixture folder, each conversation fresh, greedy sampling. Four rounds of the last-result note's wording; the tool and instruction texts are those of 0021.

| Round | Change | Result |
|---|---|---|
| 1 | `inLastResult` argument, first wording | Follow-ups right, but "undo that" was answered "The Clean Up menu and Edit > Undo don't work here", and the fixed prompt was over budget |
| 2 | The note gives the sentence to say when declining; shortened guides and one example | Declines word for word. First questions stopped filtering (see above) |
| 3 | Guides and examples restored; `"mark":"lastResult"` | First questions as in 0021. Narrowing right. "Sort those by size" kept the old order |
| 3b | The call written out as JSON with a sort hint | Sorting right, but "only the big ones" added a kind nobody asked for (video) and lost a file |
| 4, kept | Round 3's wording plus 'By size means "sort":"largest"' | Below |

The kept texts, all nine eval tests passing:

| After | Message | Lookup made | Right? |
|---|---|---|---|
| "Which files are larger than 50 MB?" (5 files) | only the big ones | 500 MB or more, largest (the filter said again, not the mark) | Yes: Xcode.dmg, movie.mov |
| the same | just the large ones | the same | Yes |
| "Which images are here?" (3) | sort those by size | in the last result, largest | Yes |
| the same | which of those is the biggest? | images again, newest | The files and the sentence ("holiday.jpg is the biggest") are right; the card lists them newest first |
| "Which files are over 500 MB?", stopped | Continue | by code: the stopped question | Yes |
| the same | keep going please | the stopped question, from the note | Yes |
| the same | finish what you were doing | the stopped question, from the note | Yes |
| "Which installers are here?" (2) | clean those up | none | Yes: "I can only look things up here. The Clean Up menu cleans up, and Edit > Undo undoes a cleanup." |
| the same | undo that | none | Yes, the same sentence |
| either of those two | Which of those is the largest? | once in the last result by largest, once installers again by newest | Files and sentence right both times; the card's order once |

- The nine questions of 0021 answer as they did there, and "Find files with report in the name." searches by name.
- **In every follow-up the files looked at were the right ones.** The misses that remain are the card's order when the question asks for one file ("the biggest") and not for sorting.
- **The model sometimes says the old filter again in place of the mark.** The result is the same files; the card then does not say "In the last result".
- "Which files have I never opened?" finds the 10 files with no open recorded, leaves out the download in progress and counts the folder and the app as 2 unknown.
- One eval run had five turns end with the model's own time-out error within a few seconds, first questions among them, and the turns after them then had nothing to refer to. The same texts ran clean before and after. The Mac was building at the time and a second copy of the app was open on the same model; the cause was not pinned down.

### Measurements on this Mac

Same Mac as 0020 and 0021, Release build, the real on-device model, `ChatMeasurementTests`.

| What | 0021 | Now |
|---|---|---|
| Instructions | 196 tokens | 196 |
| Tool definitions | 823 | 828 ("lastResult" in the mark list) |
| Together | 24.9% of 4,096 | 25.0%: 1,024 of the 1,024 allowed |
| Full turn, 20 questions, no prewarm | p50 3.23 s, p95 3.88 s | p50 3.24 s, p95 4.43 s |
| Full turn, prewarmed | p50 3.35 s, p95 4.37 s | p50 3.41 s, p95 4.54 s |
| Stop | (0020: 0.3 ms) | 0.8 ms; the next question answered in 3.15 s |
| One conversation of 30 questions | 28 answered, 2 refused, 0 started over | 29 answered, 1 refused by the content filter, 0 started over |
| Tokens before the reply in it | 990 first, at most 2,444, 2,403 last | 995 first, at most 2,455, 2,390 last (the budget is 2,457) |

- A follow-up after one question is counted at about 1,320 to 1,380 tokens: the first turn, the note (about 70 tokens for a last result) and the room kept for the summary.
- **In the app, on a fresh fake folder** (Debug build, the real model): "Which files have I never opened?" drew "No open recorded: 23 files, 839 MB" with "Last opened unknown for 7 more items, not counted". "only the big ones" drew "In the last result · 500 MB or more: 1 file, 629.1 MB" (disk-backup.img). "Which files are over 100 MB?", Stop, then "continue" drew the two files over 100 MB.

### Alternatives

- **A new session for every turn, seeded with a transcript made up from memory.** Closest to "rebuild the session from memory" as written. Every turn would then pay for the instructions and tools again with nothing cached (about a second, 0020), and made-up transcript entries are one more thing to keep right. The transform and the note give the model the same things.
- **Keep the stopped turn in the transcript.** The abandoned reply can reach a session that shares its transcript (0020).
- **Let the model work out "continue" from the note alone.** It did in the evals ("keep going please", "finish what you were doing"), but the plain word should not depend on a model.
- **Replay the old filter**: give the model the last call's JSON and ask it to add to it. No help after a duplicate scan or a summary, and a small model miscopies JSON.
- **Count the summary apart, or leave it out of the count.** One more count per turn, or a part of the prompt that is not measured.
- **"Undo that" steps back to the list before.** Offered to the owner, who chose to decline it.

## "Never opened"

### What was found

- **The 50 files, 839 MB were the fake folder, and by its construction nearly every file.** `scripts/make-fake-downloads.sh` made every file two hours back and gave a last-opened date to two. Of its 59 items, 49 files and one package had none.
- **The reader is right.** Measured on this Mac, read-only: of the 193 files in the real Downloads, 96 carry `com.apple.lastuseddate#PS`, and Spotlight's `kMDItemLastUsedDate` agrees on every one (none known to Spotlight only). 0002 stands.
- **No fixture reached the real folder.** None of the script's file names is in the real Downloads (199 items), and the tests only use temporary folders (`SafetyTests`).
- **Two faults in the chat.** It counted downloads still in progress as never opened (three in the fake folder; the list's marks skip them, `FileMarker`). And it dropped the items macOS never dates (folders, apps, links, a volume without the attribute) without saying so.
- **And one of wording.** A missing date means macOS noted no open. It notes one from Finder, the Dock or an Open panel, not from Quick Look, a drag into an app or an upload. 97 of the owner's 193 real files have no date.

### Decision

- A file with no date is found by never-opened questions and called **"no open recorded"** on the card (the owner's choice). Under it one line says what macOS records. The list's Last Opened column and the Never opened mark are unchanged.
- **Unknown is counted apart and said**: `FileSearchResult.unknownOpenCount` is the items that fit the rest of a question about opens but that macOS keeps no date for. The card says "Last opened unknown for 7 more items, not counted", and the model is told the same.
- **A download in progress is in neither** (`FolderSnapshot.File.isDownloading`).
- **The fake folder looks like a real one**: every other ordinary top-level file is given a last-opened date of ninety minutes before. The same question there now finds 23 files and 7 unknown items.
- The model's own sentence still says "never been opened", echoing the question. A line in the lookup's output asking for the other wording changed nothing (measured), so it was taken out again; the card is where the app's wording is certain.

## The Apple Intelligence label

- Under the field: the SF Symbol `sparkles` and "Apple Intelligence · on device", small and secondary. No Apple logo or artwork, no colour.
- While a reply is being worked out, a blurred stroke in the text colour sits behind the field and breathes between 15% and 45% opacity over 1.2 seconds. With Reduce Motion it holds at 30%. It is hidden from VoiceOver, which already hears "Looking through your files" from the shuffle of documents, and that animation stays.

## Consequences

- The fixed prompt has no spare token. The next tool or argument has to take something out first, or the quarter has to be decided again by the owner.
- A follow-up that also wants a real mark ("which of those are marked old?") has to repeat the old filter instead; the model did that unprompted in some eval runs.
- The note costs about 70 tokens when there is a last result, more with a summary or a stopped request, in every such turn.
- `Turn.tokensBeforeReply` is an upper bound, not an exact count.
- "Continue" is certain for six wordings in English. Others depend on the model.
- What "those" are is fixed when they are found. If files are moved to the Trash between two questions, the note's count is the old one until the next lookup, which always reads the folder as it is.
- Not done: cleanups and Undo from the chat, New Chat, the selection as context (Prompts 2 and 4).
