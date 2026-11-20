# 0025. One card, one sheet, one progress line, one state, and the first run

Date: 2026-11-19 · Segment: UI polish, segment 2 (sheets, cards, states and first run)

Segment 1 ([0024](0024-design-system-and-window-shell.md)) put the window's shell on the tokens and left the sheets as they were: the card's frame written out twice, a header, a footer and a size per sheet, six progress lines, a large centred symbol on every confirmation. This segment puts them on four shared components, adds a welcome shown once, an About line and an app icon, and makes the wording consistent. It changes looks only: no cleanup behaviour, no file logic, no prompt or tool text.

Design skill used: `design-taste-frontend`, its app-screen rules (figures as type and never tiles, one answer figure per screen, colour off the chrome, a state keeps its frame and names the next step).

## Decisions

### Components

- **`Card`, with `CardHeader`, `CardFigures`, `CardFigure` and `CardActions`** (`Card.swift`). The outline, padding and radius are in one place; the chat's two cards, every confirmation, every result and the preview use it.
- **One card per sheet, above the list it sums up.** The numbers moved out of titles and footers into the card's figures, so a number is said once. A confirmation's title is now a short question ("Move what is ticked to the Trash?") and no longer carries a count.
- **In the two selection lists the card is a layout, not an outline.** The preview's groups get `CardHeader` as their section heading, and a run in Activity is a `CardHeader` row. The owner chose this over outlined cards there.
- **`SheetScaffold`, in three sizes** (`Design.Sheet`: small, medium, large, through `.sheetSize(_:)`). Layout only: each sheet keeps its own closing, shortcuts, roles and key handling, so every default key is what it was. The undo summary moved from its own size to medium, the "log unavailable" sheet to small.
- **`ProgressLine`**: bar or spinner, the count in words, a slot for the work's own Stop button. The search bar's button is now "Stop", as its tooltip always said.
- **`StateView` and `StateBar`**, on `ContentUnavailableView`: one outline symbol, a title, one sentence, at most one action.
- **Tokens:** `Design.Sheet` and `Size.progressBarCompact` added; `Size.confirmationSheet`, `Icon.large` and `Chat.cardGap` removed with their last use.

### States

- **Access blocked has one button, Open privacy settings.** The folder is read again when the app comes back to the front while access is blocked (one more condition in the hook that already rereads it for a waiting cleanup card). ⌘R still tries again. `lock.fill` became `lock`.
- **The activity log's bar keeps two buttons** (Try again, Start a fresh log). It is the stated exception: both are ways out, and removing one would strand a user with a damaged log.
- **An empty folder and an empty Activity have no button.** There is no next step in the app, and a button that only switches place is not one.
- **Loading has no count and no Stop.** The scanner reports no progress and the list model offers no cancel; adding either is engine and model work, outside a looks-only segment. The same goes for a Stop while one cleanup is carried out.

### First run, About and the icon

- **The welcome is a sheet on the main window**, the owner's choice over a separate window. The first scan waits until it closes, so the Mac's question about Downloads comes after the promise. Closing it by the button or by Escape both count as shown.
- **`FirstRun` lives in `FileStoreCore`** beside `CleanupSettings`, taking a `SettingsStore`, so `FirstRunTests` covers "once and never again" with a store in memory. It holds no file logic. The owner chose this over an app test target.
- **Existing users see the welcome once too.** Telling them apart would take a guess from other defaults.
- **About is the system's own window** (`AboutCommands`), with the one-line description passed as its credits. The text's font and colour are AppKit values, so they sit in the tokens file (`Design.About`), the label colour keeping it readable in dark mode.
- **The icon is an Icon Composer file, `SmartOSFileStore/AppIcon.icon`**, written by hand from Xcode's template: a black fill and one layer, `Assets/mark.svg` (a download settling into a tray, in white). `ASSETCATALOG_COMPILER_APPICON_NAME: AppIcon` builds it, and the system cuts the shape and makes every size. There is no set of PNG sizes: on macOS 27, the only system the app runs on, an icon from PNGs is shrunk and set on a grey plate, whether it brings its own rounded shape or fills its square (both were built and looked at).
- **The version stays 0.2.0** until 0.3 is finished.

### Copy

Every string in the catalog was read once. The rules are in `docs/design.md`, Copy: one word for one thing (Trash, Kept, cleanup, tick, Stop and Cancel, listed), a full stop on a reason that is a sentence and none on a short status, and wording that reads right for one and for many. Text the model reads (`PromptLibrary.swift`, `ToolOutput`, `FileQuery.words`) and the folder name "Old downloads" were not touched. `TidyNowTotals.sentence` went with its last use.

## Alternatives

- **Outlined cards around each group and each run.** The Mac's list has no spacing between rows (`listRowSpacing` is unavailable on macOS), so the outline would touch the next card and sit against the selection as a box in a box; rebuilding both lists as stacks would mean rebuilding selection, arrow keys, right-click and Undo Selected by hand.
- **A separate welcome window.** One more window to manage and restore, and the main window would be live behind it, so the scan could not simply wait for it.
- **An app test target for the welcome.** Targets are added only when asked (0024 turned one down).
- **An icon set of PNG sizes in an asset catalog**, as first built. macOS 27 sets it on a grey plate (above).
- **A custom About window.** A window to design and keep, for what the system already draws.
- **The description as the Info.plist's copyright line.** No code, but Finder's Get Info would show it as "Copyright: Keeps your Downloads folder tidy…".
- **Two buttons on the access-blocked state** (as before). One action per state was the brief, and rereading on return makes the second unnecessary.
- **A figure card on Stop keeping all.** It is a question, not a result, so it has the shared header and footer and no card.

## Why

- A result looked different in five places, and a number was often said twice (title and footer). One card and "say it once" fix both.
- The preview has to make three things plain before the list is read: how many files, how much space, and that nothing changes yet. The card's two figures and its one sentence do that; the footer no longer repeats them.
- Shared components hold only layout, so the safety rules stay where they were written and reviewed: a destructive button is never the default, Escape never confirms.

## Consequences

- A new sheet starts from `SheetScaffold`, a new result from `Card`, a new empty or failed screen from `StateView`. `docs/design.md` lists every state per screen; a new screen adds its rows there.
- A copyright line, when there is one, goes in `NSHumanReadableCopyright`; the About window shows it under the description.
- The icon can be refined in Icon Composer (in Xcode's Open Developer Tool menu): open `SmartOSFileStore/AppIcon.icon`, which has glass and shadow turned off, and save it in place.
- Settings is still not redesigned.
