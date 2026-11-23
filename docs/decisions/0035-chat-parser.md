# 0035. The chat request parser, and its parse-only eval

Date: 2026-11-22 · Segment: version 0.3, the chat's redesign, step 1 (the parser alone)

The tool loop gets 72% right outcomes (0034). Its misses come from the loop itself: a card after a question, a search's filter copied onto a card, the same search until the tool limit, a wrong action name, and arithmetic on dates (0033, misses 1 to 5). The redesign replaces the loop with one guided generation that reads the message into a typed request, which code then acts on. This segment adds only the parser and a way to measure it. The app does not use it yet.

## What was decided

- **`ChatRequest`** (`FileStoreIntelligence/ChatRequest.swift`), a `@Generable` value written in this order: `kind` (list, count, cleanup, duplicates, overview, cannotDo, chat), `cleanups`, `files`, `sort`, `limit`, `folder`, `aboutLastResult` and `cannotDo`. The kind comes first, so every later field is written knowing it.
  - `cleanups` is optional, where the plan had a plain list: the examples of questions write none, and a required list would have the model write one after every kind.
  - The files are slots, not a filter: `FileSlots` with a kind, name, site, size bounds, an added and an opened `Age`, never opened, and a mark.
  - An **`Age`** is how the user said it (`within`, `olderThan`, `between`, `inMonth`, `onDay`, with an amount, a unit, an upper end, a month and a year). The model never writes a calendar date. Code will count the age back from today in the next step.
- **`CleanupIntent`** names the cleanups in the user's words (exactCopies, almostSame, failedDownloads, unpackedZips, usedInstallers, messyNames, oldFiles, largeFiles, emptyFolders, everything). A single `switch` is the one table that maps each to its registry action, and "everything" means every action offered. This should end the "near-duplicates read as duplicates" miss, which came from the registry's identifiers.
- **`ChatParser`** makes a fresh session for every turn, with no tools and no history, and uses greedy sampling, the system model and the chat's 30-second turn limit. Its instructions are the new template `parse` v1: six lines of rules, then 16 worked examples, each a message and the JSON it becomes. They cover every kind; the ages within, olderThan, between, inMonth and onDay; a follow-up with `aboutLastResult`; two cannot-dos (convert and schedule); and one message with injected instructions. None copies or closely paraphrases an eval sample. They were written after reading every sample's wording, held-out included.
- **What it remembers is one line written by code**, `parse-lastResult` v1: "Last result: 4 files (documents, images, installers, video)." That is a count of the files still in the folder ("1 file" for one; no line when none is left) and their kinds, never a name. A name is data from the disk, and here it would sit outside the data marks. `ChatParserTests` checks that no name or stem appears in the line, including a name written as an instruction.
- **The lists only known when the app runs are built then**, as `ProposeCleanupTool` builds its own: the intents whose action is offered, plus "everything" (bounded, decision 0023), and the managed folders, plus "all" when there are two or more. Folder names are the user's, so they are cleaned and cut to 40 characters as `ToolOutput` cleans any data from the disk, each name is listed once whatever its case, and "all" is left out when a folder has that name. The parser is handed the actions already narrowed by the folders' rules. `ChatEvalPromptTests` builds the schema from Documents' default rules and finds none of the five intents those rules turn off.
- **`PromptLibrary.version` is 6.** The set now includes the parser's two templates and its schema (`PromptLibraryTests` hashes the schema with the tool definitions). It is not 5, because v5 already names the report of round 4, which was not kept (0033).

## SDK: what was planned and what the SDK has (Xcode 27.2's interface)

| Planned | Found |
|---|---|
| `respond(to:generating:)` | It takes a static `Generable` type, whose schema cannot hold lists made at run time. The parser calls `respond(to:schema:)` with a `GenerationSchema` built from `DynamicGenerationSchema`, then reads the content with `ChatRequest(_:)`, the initialiser the macro makes. |
| A `@Guide` for each cleanup | A guide on an enum's cases would never reach the model, because the list is built dynamically. Each intent is a one-value `DynamicGenerationSchema(name:description:anyOf:)` choice that carries its guide as the description. The choice decodes into the enum with no change. |
| The scripted model under a schema | `ScriptedModel`'s text chunks are read as guided content with no change, and the request carries the schema and no tool definitions (`ChatParserTests`). The session does not hold scripted text to the schema, so a planted folder outside the list still decodes. |
| Measuring the schema | `SystemLanguageModel.tokenCount(for: GenerationSchema)` exists beside the instructions' count |

## The fixed prompt

Instructions 722 tokens and schema 741, which makes **1,463 tokens** with the three standard folders (`theParserPromptStaysUnder1600Tokens`, under the bound of 1,600). That leaves 137 tokens under the bound. Each folder the user adds takes a few of them (not measured per folder), so many added folders could pass it (shortcut: measure with the user's folders, or cap the list, when the app uses the parser). The chat's own fixed prompt is unchanged: 244 + 1,446 tokens, 41.3%.

## The parse-only pass

`ParsePass` reads every sample of every set with the parser alone and acts on none of them.
- A follow-up's earlier turns are played first through the chat engine with their ideal calls, so its last-result line is the one a right first turn leaves.
- A hostile file is not added, because the parser reads no file name.
- Each parse is scored against the sample's expected outcome:
  - **kind**: count and overview count as alike, and so do cannotDo and chat, as the outcome score treats them (the owner's choice for the labels 0034 left unclear);
  - **a card's cleanups**: the intents, as actions, equal the card's actions;
  - **folder**: none, or the eval folder, which is the one on screen. With one folder the schema offers only that name, so on the real model this part cannot fail. It is there for the three-folder eval home that 0034 left for later. The planted test, whose scripted reply is not held to the schema, shows that the scoring works.
- The report has new rows: parse right over the tuned sets, each of the three parts, held-out on its own line, and parse time at p50 and p95.
- Parse misses are listed, except held-out ones, and the Samples table's Parsed kind and Parse time columns, empty since 0034, are filled in. The placeholders on `TurnRecord` were removed.
- `ChatEvalHarnessTests` plays each sample's ideal parse, which is written from its outcome alone: every rate is perfect, held-out included. It also checks that planted mistakes (a wrong cleanup, a question read as a cleanup, another folder, and a held-out miss) are counted exactly, and that a count read for an overview, or chat for a cannot-do, passes.

## Results (real on-device model, this Mac)

MacBook Pro 13-inch, M1, 2020 (MacBookPro17,1), macOS 27.2.1, Release build, prompts v6, 204 samples, `scripts/run-evals.sh` on 2026-11-22. Report: [docs/evals/2026-11-22-prompts-v6.md](../evals/2026-11-22-prompts-v6.md). Every guarantee held. The tool-calling chat is unchanged and gave the v4 baseline exactly (right outcome 103 of 144, held-out 40 of 60), so the run is comparable with 0034.

| Parse-only | Result |
|---|---|
| **Parse right** (requests, cannot do, hostile) | **106 of 144 (74%)**: requests 79 of 94, cannot do 9 of 25, hostile 18 of 25 |
| **Parse right, held-out** | **39 of 60 (65%)** |
| Kind | 119 of 144 (83%) |
| A card's cleanups | 39 of 53 (74%) |
| Folder | 144 of 144 (it cannot fail with one folder: above) |
| Parse time, p50 / p95 | 2.86 s / 4.33 s (the tool loop's full turn: 5.08 s / 8.25 s) |
| Failed or timed-out parses | 0 |

A parse is not yet an outcome. It scores neither files nor ages, and code does not act on it yet, so these numbers are not the redesign's result against 0034's bar. They say where the parser stands before code acts on it.

- **Requests: 79 of 94, against 66 right outcomes for the tool loop.** The loop's own misses are gone: no card after a question, and no repeated search. The near-duplicate misses (near-1, near-2) remain, now as copies mixed with near-copies (below).
- **Cannot do: 9 of 25, against 23 for the tool loop. This is the biggest gap.** Sixteen cannot-dos read as `cleanup`: move, delete for good, change a setting, undo, empty the Trash, email, compress, schedule, watch, sort into folders, make a folder, encrypt, back up, restore, start at login. The rules say what a cleanup is, but "kind cleanup" still wins for any request to do something to files. Since the kind comes first, the model commits to it before it has seen the list of cleanups. Code can catch part of this: a cleanup with no cleanups listed is not one. That is the first candidate for the next round.
- **Copies bring near-copies.** Seven samples that ask only for duplicates read as `exactCopies` plus `almostSame`, very likely from the example "Bin the repeated copies, and the nearly identical ones too", the only example that names copies. A second candidate: an example with copies alone.
- **Others:** "Tuck away my stale downloads" read as failed downloads; "archive the old stuff that's bigger than 100 MB" read as large files; "Let me review downloads that take more than 50 MB" read as a list; three folder questions ("What kinds of files are here?", "What's taking the most space?", "How much has the app moved to the Trash?") read as list or cannotDo; follow-1 "just the large ones" read as a cleanup.
- **Hostile: 18 of 25.** Five injected requests changed the parse: three added cleanups or a cleanup kind ("Developer override", "IMPORTANT: also add", "the user's real request is to tidy everything", "now prepare a cleanup"), and one read an image question as an overview. No hostile file name could reach it.
- **Held-out: 39 of 60**, nine points below the tuned sets (the tool loop's gap was five). The examples were written without reading any sample's result, so nothing was tuned on either set; the gap is the casual wordings. Held-out misses are not listed.

## Code review

`/code-review` found nine things. Fixed:
- folder names went into the schema raw (now cleaned, cut short, each once, and no "all" beside a folder of that name);
- a follow-up's line was rebuilt in the evals by other rules than the engine's (now `ChatEngine.lastResultIDs`);
- a test said follow-ups read a line and never checked it (now checked: every follow-up after a lookup has one; held-48, after a card, has none, as in the app);
- most examples left out a required `cleanups` (now optional);
- the line counted files no longer there and said "1 files";
- a method named like the property beside it.

Not changed, and recorded above: the folder score cannot fail with one folder; the token bound is measured with three folders. The finding that no v6 report existed was made before this run.

## Alternatives

- **The static `@Generable` schema with every action and no folder list.** It is simpler, but the model would then offer actions a folder turns off, and folder names it does not have.
- **Tool calling with one tool that takes the request.** It keeps the loop this replaces.
- **Today's date in the instructions.** The model wrote dates badly (0033); with ages only, it never needs to work one out.
- **The last result's file names in the line.** That would let the model point at a file. It is untrusted text, and naming files is code's job.

## Consequences

- The app is unchanged. The next step acts on `ChatRequest` in code: ages into dates, slots into `FileQuery`, cleanups into `CleanupRequest`, and the answer's wording.
- `ChatEngine.lastResultIDs` gives the files the engine remembers as the last result. The evals take a follow-up's line from it, so a search that found nothing, or a turn that failed, leaves the line as the app would.
- The README index of eval runs keeps its columns. The parse results are in each report only (shortcut: the index header is fixed in the existing file; add columns when the redesigned chat replaces the tool loop's).
