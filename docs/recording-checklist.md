# Recording checklist

About 75 seconds, silent, captioned, black-and-white commercial look. Record on the demo home only.

## Before

1. Turn on Do Not Disturb. Hide desktop icons, plain dark wallpaper, dark mode for the whole video. Close every other app and hide menu bar extras.
2. In Terminal, in the repository: `scripts/run-demo.sh --reset`. The window opens at 1440 × 900 in the middle of the screen, on Downloads, with Desktop and Documents on and twelve weeks of history.
3. Record the app window only (Screen Studio, or ⌘⇧5 › Record Selected Window at native resolution). One clip per shot, two or three takes each. Run `scripts/run-demo.sh --reset` between takes that change files (shots 4 to 6 and 9).
4. Move the pointer slowly and in straight lines; pause a full second before and after each click. Never show the Dock, your name, notifications or a Finder window of your real folders.

## Shots

| # | Time | On screen | Caption |
|---|---|---|---|
| 1 | 0:00–0:04 | Title card on plain black: app icon and name | Smart OS File Store. A Mac file browser that cleans up after itself. |
| 2 | 0:04–0:10 | Downloads. Scroll the list once, click the Size header to sort | Your folders in one clean window. |
| 3 | 0:10–0:18 | Click Storage. Hover a bar segment, then the "What you can get back" rows | See what is taking space, and what you can get back. |
| 4 | 0:18–0:28 | Back to Downloads, click Tidy now. The preview fills in: duplicates, used installers, unpacked zips. Untick one file | One click finds duplicates, used installers and leftovers. |
| 5 | 0:28–0:34 | Pause on the preview, pointer near Tidy up, click it, then Tidy up in the question. Summary appears | Nothing changes until you confirm. Files go to the Trash. |
| 6 | 0:34–0:41 | Click Activity, click Undo on the newest run, files return to Downloads | Every change can be undone. |
| 7 | 0:41–0:48 | Click Desktop, then Documents. Open Clean Up › Find Duplicates on Documents: nothing ticked | Works on Desktop, Documents and any folder you add. |
| 8 | 0:48–0:56 | ⌘K, type "Which installers have I already used?", the thinking animation, the answer rows | Ask in plain English. |
| 9 | 0:56–1:04 | Type "Clean up the duplicates on my Desktop". The card appears, click Confirm | Apple Intelligence, on device. Nothing leaves your Mac. |
| 10 | 1:04–1:10 | Activity: the Insights chart, switch Each week › Running total | Track the space you get back. |
| 11 | 1:10–1:16 | End card on plain black: three lines and the GitHub link | Swift 6, SwiftUI, SQLite, Foundation Models. Crash-safe undo, 800+ tests. github.com/Quaden2307/smart-os-file-store |

Captions: white on a dark bar, one line, sentence case, at least 2.5 seconds each. The test count on the end card is true as of 2026-11-21 (834 tests); use the count from the last test run on the day.

## Watch out

- **Shots 8 and 9 (the chat) did not pass a check with the real model overnight** (docs/demo.md, Chat on the demo home). Take several takes; if they still fail, ask "How many files are on my Desktop?" for shot 8 and "Find duplicates on my Desktop" for shot 9, or drop them.
- The seeded history's Undo buttons do nothing useful: use Undo only on the run you made in shot 5.
- Send the raw clips back and I will cut them (trim, speed up typing, captions, title and end cards) with ffmpeg.
