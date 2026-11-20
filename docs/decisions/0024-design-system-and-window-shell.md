# 0024. The design system and the window shell

Date: 2026-11-19 · Segment: UI polish, segment 1 (design system and the main window's shell)

Every view carried its own numbers: nine text styles and two literal font sizes, eleven stack spacings, thirteen paddings, three radii, six animation curves, and four copies of one tag. This segment puts the values in one file, adds a check that keeps views on them, writes the rules down in `docs/design.md`, and restyles the shell of the main window. It changes looks only: no engine code and no behaviour.

## Decisions

### Tokens and the check

- **One file, `SmartOSFileStore/DesignTokens.swift` (`enum Design`):** five type roles, six spacing steps, two radii, two colours, icon sizes, four shared sizes, two animations, and the chat bar's own values. A token exists only if a view uses it: no view uses a colour for a meaning yet, so destructive and warning are named in `docs/design.md` and added with their first use.
- **Type roles are system text styles** (title 2, headline, body, callout, subheadline: 17, 13, 13, 12 and 11 pt), so they follow the user's text size. `.caption` (10 pt) is gone outside the chat: nothing is smaller than 11 pt.
- **Monospaced digits everywhere, set once.** Each role includes them, and the window and Settings set them at their root, which sheets inherit (checked in the duplicates preview: "21 bytes", "22 bytes" and "19 bytes" start on one edge). The 39 per-view `.monospacedDigit()` calls were removed. The placeholder that stands in for a checkbox is 16 pt, the width a checkbox takes in a row (it was 14, which left kept rows 2 pt out of line with the rows under them).
- **A 4 point grid with one half step.** `tight` (2 pt) is allowed between the lines of one block of text, inside a badge, and above and below a list row. Fixed sizes (frames, column widths, a view's own constants) may stay numbers when they are multiples of 4.
- **The check is a test in `FileStoreCoreTests`** (`DesignTokenTests`), reading the app's sources as text, as `SafetyTests` does and with its helpers. It fails on a font that is not a role, a raw font size, a colour literal or named hue, a gradient, a shadow, a number in a padding, spacing, radius or duration, a raw animation curve, `.animation(` (which would skip Reduce Motion), and an off-grid frame, column width or `CGFloat` constant. A self-test feeds it one bad line per rule. It also checks the spacing steps themselves, and that only the chat's files use `Design.Chat`.
- **Accent: the one chosen in System Settings** (the owner's choice). The app defines no colour of its own. It appears on Tidy now, the selected row and the filter's selected segment, all drawn by the system.

### The shell

- **Sidebar:** two system sections, Folders (Downloads) and History (Activity), each row with the system `.badge()`: items in the folder, cleanups in the log (undos are not counted). Zero shows nothing. VoiceOver reads the count with its noun.
- **Toolbar:** Tidy now is the one prominent item (`.borderedProminent`, title showing, symbol `checklist`). Clean up (`ellipsis.circle`) and Refresh are icon-only. The sparkle symbols on Tidy Now are gone: the sparkle belongs to Apple Intelligence. Order is unchanged, so the system's overflow menu takes Refresh first and Tidy now last.
- **File table:** inset style without stripes, the system's 24 pt rows, column widths on the grid. Kind is wider (132 ideal: "Plain Text Document" fits). The date columns' minimum is 144, so a date never truncates; a narrow window scrolls the table sideways instead.
- **Badge:** one `Badge` view replaces `MarkBadge` and three hand-built copies: 11 pt, secondary text, quaternary fill, radius 4.
- **Bars:** filter bar, progress line, notices and status bar share one inset (12 across, 4 down). The filter is segmented while it fits and a pop-up menu when it does not (`ViewThatFits`).
- **Status bar:** the two debug-build lines with the scanned folder's and the log's paths are gone from the window (the owner's request during the segment). A debug build shows them as the status bar's tooltip, so a hand test can still see it is on a fake folder; Settings shows the log's path as text, with Reveal in Finder.
- **Window:** default 1,280 × 720, minimum 720 × 480 beside the sidebar (it was 1,080 × 400, too wide to ever be narrow). macOS already saves the window's frame and the sidebar's width (`NSWindow Frame main`, `NSSplitView Subview Frames main, SidebarNavigationSplitView` in the app's defaults), so no code was added for it.
- **Motion:** two animations (0.15 s and 0.25 s), always through `.motion(_:value:)`, which animates nothing under Reduce Motion. Used for switching place, and the Activity disclosure arrow and its rows. The chat's own animations go through it too.
- **Copy:** sentence case inside windows and sheets (about 75 strings); menus keep Title Case, and a command keeps its menu name wherever it is a menu item or is pointed at. "Show in Finder" became "Reveal in Finder". The preview titles now read "Old downloads", the same as the folder.

### The chat bar keeps its look

Its values moved into `Design.Chat` unchanged, off-grid ones included (the owner's choice between "keep its look" and "nothing off-grid"). `ChatLayout` moved there too. It is the only place the check accepts off-grid values, because they sit in the tokens file.

## Alternatives

- **A fixed accent colour in an asset catalog.** Rejected by the owner: the system accent is more native and Increase Contrast needs nothing from us.
- **A strict 4-only grid.** Rejected: a badge with 4 pt vertical padding is taller than a 24 pt row allows, and two lines of one text block 4 pt apart read as two blocks.
- **A test target for the app, or SwiftLint.** Rejected: targets are added only when asked, and no third-party tool is approved. Reading sources as text is the pattern the repository already has.
- **Alternating row stripes, as Finder has.** Rejected: with hairline separators and a filled selection, stripes are a third way of telling rows apart.
- **Animating the file table's rows when the filter changes, and the progress line sliding in.** Tried and removed. With 5,000 files the first added about 50 ms of main-thread work to a switch that took about 1 ms, and the second animates the table's height, which lays the table out again every frame.
- **Primary-coloured badge text.** Not taken: the owner asked for calmer badges. See the contrast numbers below.
- **Wrapping `.secondary` and friends in tokens.** Rejected: they are already the system's semantic tokens, and 126 call sites would only get longer.

## Measurements

- Contrast, measured from renders of the app. Primary text is far above 4.5:1 everywhere. The system's `.secondary` text ("Never", status lines) is 3.9:1 in light mode, 5.9:1 in dark, 10.7:1 and 8.6:1 with Increase Contrast. Badge text on its fill is 3.8:1 light, 4.9:1 dark, 6.1:1 and 4.0:1 with Increase Contrast. Light-mode secondary text is therefore below 4.5:1: it is the system's own secondary label colour, the one Finder uses, and Increase Contrast is the system's remedy.
- Increase Contrast and Reduce Motion can be turned on for one launch only with `-increaseContrast YES -reduceMotion YES`, which is how they were checked without touching the Mac's settings.
- Found while measuring, and not from this segment: with 5,000 files, switching the filter from a mark back to All keeps the main thread busy for more than two seconds inside the table's own row-height pass. The last commit before this segment does the same. Not fixed here (this segment changes no behaviour); reported to the owner.

## Not changed, for later segments

- Sheets, Activity rows and Settings are on the tokens (values snapped to the nearest step) but not redesigned. Known inconsistencies left in them: confirmation sheets title their question in `sectionTitle` while previews and results use `windowTitle`; confirmations and results open with a large centred symbol; a reason line is one line in some rows and two in others; one sentence is middle-truncated (`ActivityRows`); preview sheet sizes are still local numbers; `lock.fill` sits beside outline symbols in the scan error.
- `arrow.down.circle` is both the Downloads place and the Failed Downloads action.
- The app's menus were not touched.

## Consequences

- A new view reads `docs/design.md` and uses `Design`. A value that does not exist is added to the tokens and the document first; a raw one fails the tests.
- Dropping `Design.Chat` later means snapping the chat to the grid, a visible change to decide on its own.
