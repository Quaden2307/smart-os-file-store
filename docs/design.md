# Design

How Smart OS File Store looks, and the rules every view follows. The values live in one file, `SmartOSFileStore/DesignTokens.swift` (`enum Design`). `DesignTokenTests` fails when a view writes its own font, colour, spacing, radius or animation. The reasons for the choices are in [decision 0024](decisions/0024-design-system-and-window-shell.md).

Read this before adding or changing a view.

## Rules

The app should look like a Mac product a person would pay for, and stay native.

- **Black, white and greys**, in light and dark mode, from the system's semantic colours, so both modes and Increase Contrast work without code of ours. One accent, the one chosen in System Settings, on the primary button and the selected row only. Any other colour carries a meaning: a destructive action, a warning, a chart series.
- **None of these:** gradients, glows, emoji, decorative sparkles (the Apple Intelligence indicator in the chat bar is the one sparkle), cards inside cards, centred hero text in a working screen, a shadow heavier than the system's.
- **San Francisco only**, in five roles. Every number has monospaced digits.
- **A 4 point grid.** Every padding and gap is a named step.
- **System controls and materials first.** Draw something custom only where no system control does the job, and say why in a comment. Today that is the badge and the chat bar.
- **Density like Finder's list view**, not a web dashboard. Hairline separators, not boxes.
- **Text is sentence case, short and specific.** No exclamation marks.

## Tokens

### Type: `Design.Typography`

Built on the system's text styles, so they follow the user's text size. Each role includes monospaced digits. The window also sets monospaced digits at its root (`ContentView`, `SettingsView`), so text with no role lines up too. Never add `.monospacedDigit()` to a view.

| Role | Size | Use |
|---|---|---|
| `windowTitle` | 17 pt semibold | The title of a sheet; a card's figures |
| `sectionTitle` | 13 pt semibold | A card's or a group's heading |
| `body` | 13 pt | File names, and everything with no other role (the default: no modifier needed) |
| `secondary` | 12 pt | Status lines, explanations, the second line of a row |
| `caption` | 11 pt | Badges, notes beside a value. Nothing is smaller |

A weight may be added to a role (`Design.Typography.caption.weight(.semibold)`, or `.fontWeight(.semibold)`). A size may not.

### Space: `Design.Space`

| Step | Points | Typical use |
|---|---|---|
| `tight` | 2 | Half a step, in three places only: between the lines of one block of text, inside a badge, and above and below a list row |
| `xs` | 4 | Vertical inset of a bar; a title and its subtitle |
| `s` | 8 | An icon and its label; items in a row |
| `m` | 12 | Horizontal inset of a bar; a card's padding; a sheet's footer |
| `l` | 16 | A sheet's header; groups inside a sheet |
| `xl` | 24 | Between the figures of a card |

A fixed size (`.frame`, a table column's `.width`, a view's own `CGFloat` constant) may be a number, and must be a multiple of 4.

### Radius: `Design.Radius`

| Token | Points | Use |
|---|---|---|
| `badge` | 4 | Badges |
| `card` | 12 | Cards |

Buttons, fields, the table's selection and sheets keep the radius the system gives them.

### Colour: `Design.Colour`

| Token | Value | Use |
|---|---|---|
| `badgeFill` | `.quaternary` | A badge's background |
| `hairline` | `.separator` | A card's outline. Between regions use `Divider()` |

Text uses the system's `.primary` (the default), `.secondary` and `.tertiary` directly. The accent on the primary button and the selected row comes from the system, and a destructive button from `role: .destructive`; neither needs a colour of ours. No view uses a colour for a meaning yet. The first that does adds a token here (system red for destructive, system orange for a warning) and a row to this table. A named colour (`.red`, `Color(…)`, `NSColor`) anywhere else fails the check.

### Icons: `Design.Icon`

SF Symbols, outline variants, regular weight. A filled variant only where the outline has no equivalent or a filled state means something (Stop while the chat answers).

| Token | Value | Use |
|---|---|---|
| `size` | 16 pt | A file's icon; a symbol in a row |
| `column` | 20 pt | The width a row's symbol sits in, so the text after it starts on one edge |

The one large symbol is the system's, in a state (`StateView`). No sheet has a symbol at its top.

### Sizes: `Design.Size`

`progressBar` 240 · `progressBarCompact` 120 (one row in a list of several things in progress) · `sizeColumn` 72 (a size at the end of a row) · `checkbox` 16 (the width the system checkbox takes in a row).

### Sheets: `Design.Sheet`

Every sheet is one of three sizes, set with `.sheetSize(_:)`. A sheet does not write its own frame.

| Size | Points | Use |
|---|---|---|
| `small` | 400 wide, as tall as its content | A question, a short notice, the welcome |
| `medium` | 620 to 700 × 420 to 540 | A list to review and its result: the preview, Tidy Now, an undo's summary |
| `large` | 820 to 1,000 × 520 to 640 | Two files side by side |

### About: `Design.About`

The About window is the system's standard one. Its one line of ours is AppKit text, so its font (small system) and colour (label) are here and nowhere else.

### Motion: `Design.Motion`

| Token | Value | Use |
|---|---|---|
| `quick` | 0.15 s, ease out | A selection, a disclosure arrow, switching place |
| `standard` | 0.25 s, ease in and out | Rows arriving or leaving a short list (a cleanup's files in Activity) |

Always through `.motion(_:value:)`, which animates nothing when Reduce Motion is on. `.animation(` in a view fails the check, and so does a raw curve or duration. `withAnimation` is for the rare change made in code (the conversation scrolling to its end): it takes a token and checks Reduce Motion itself. Do not animate the layout of the file table: with thousands of rows every frame is expensive. Nothing performs an entrance: motion answers something the user did.

### The chat bar: `Design.Chat`

The chat bar was designed before the tokens and keeps its exact look. Its values sit in `Design.Chat`, some of them off the grid (5, 6, 14, 18 and 22 points; radii 14 and 16; a 10 pt caption; its own six animations). This is the one exception. Nothing outside the chat files uses `Design.Chat` (the check fails if one does), and a new chat view uses the main tokens wherever one fits.

## Components

### Sidebar row

A `Label` in a `List` section, with the system's `.badge()` for the count.

- Do: one outline symbol; a section heading in sentence case; a count whose noun is clear from the row ("Downloads 59" is items) and is spoken in full ("59 items").
- Do not: colour the symbol, show a count of zero, or draw the selection yourself.

### Table row

A SwiftUI `Table`, inset style, no alternating stripes. The system's row height (24 pt).

- Do: put the name first with its icon; right-align sizes (`.alignment(.numeric)`); show a missing value as a grey dash with a spoken label (`NoValueCell`); truncate names in the middle, on one line.
- Do not: set a row height, add stripes or a header fill, left-align a number, or put more than a badge or two after a name.

### Badge

`Badge(Text("Kept"))`: caption, secondary text, `badgeFill`, radius 4. Custom because the system has no quiet inline tag.

- Do: one or two words that state a fact about the row ("Kept", "Stays", "Undone"). The words carry the meaning.
- Do not: colour it, use it as a button, put it above a heading, or rebuild it by hand in a view.

### Card

`Card` (`Card.swift`): padding `m`, an outline of `hairline` at radius `card`, no fill and no shadow. It is the one way a result is summarised: what a cleanup would do, what it did, what an undo put back, what the chat found. Its parts, top to bottom, each optional:

- `CardHeader`: a title in `sectionTitle`, one line under it in `secondary`, and at the far end a number, a date or a button.
- `CardFigures` of `CardFigure`: each number in `windowTitle` with what it counts under it in `caption`, `xl` apart. VoiceOver reads a number and its label as one.
- One sentence in `secondary`.
- `CardActions`: a sentence on the left, the buttons at the far end, the main one last.

Where it is used: one card at the top of the preview, of each confirmation, of each result (a cleanup's, Tidy Now's, an undo's), and each result and cleanup in the conversation.

- Do: one card per sheet, above the list it sums up. Say the number once: in the card, not again in the title or the footer.
- Do: in a list, give a group or a run the card's layout without its outline: `CardHeader` as the section's heading (the preview's groups) or as the row (a run in Activity), with the list's own separators. The Mac's list cannot put a gap between rows, so an outline there would sit against the selection as a box in a box.
- Do not: put a card inside a card, box a region of the window (use `Divider()`), or draw the outline by hand.

### Sheet

`SheetScaffold` (`SheetScaffold.swift`), in one of the three sizes.

- Header: the title in `windowTitle` with the header trait, one line under it in `.secondary` saying what will happen, padding `l`, then a `Divider()`. Left-aligned, no symbol.
- Content: usually one card, then a list. A sheet with nothing to list has no content, and the header's divider is its only one.
- Footer: a `Divider()`, padding `m`. On the left, what belongs to the list: Tick all and Tick none, a progress line, a note. On the right the buttons, Cancel before the main one.
- The main button is the default action. A button that sends files to the Trash is `role: .destructive` with ⌘⌫, and then Cancel is the default, so Return and Escape both decline (`CleanupConfirmationSheet`).
- A sheet named after a command carries the command's name ("Find Duplicates", "Tidy Now"). A question is a short question ("Move what is ticked to the Trash?"), with its numbers in the card.

- Do: make three things plain in a preview without reading the list: how many files, how much space, and that nothing changes until the main button. The card says all three.
- Do not: centre a header, give a sheet its own frame, repeat the title in the content, or make a destructive button the default.

### Progress

`ProgressLine` (`ProgressLine.swift`): a bar of `progressBar` once the total is known and a small spinner until then, the count in words in `secondary` ("Moving file 3 of 12 to the Trash…"), and at the far end the work's own Stop button where the work can be stopped.

- Where: the bar above the status bar while a cleanup looks for files, a sheet's footer while files move, a card in the conversation.
- Stop ends work in progress and keeps what is done. Cancel leaves before anything started. Reading the folder and carrying out one cleanup cannot be stopped, so they have no button.
- Do not: show a bar without its count, stack the text under the bar, or add a second spinner beside it.

### Primary and secondary buttons

System button styles only.

- Primary: one per window or sheet. In the toolbar it is `.borderedProminent` with its title showing (Tidy now). In a sheet it is the default action (`.keyboardShortcut(.defaultAction)`), which the system fills with the accent.
- Secondary: the default bordered style. In the toolbar, icon only, with a label and a tooltip.
- Destructive: `role: .destructive`. Never the default action without a confirmation that names what goes.
- Do not: two filled buttons side by side, a custom `ButtonStyle`, a tinted secondary button.

### States

A screen with nothing to list says why, the same way each time. `StateView` (`StateView.swift`, on the system's `ContentUnavailableView`): one outline symbol at the system's weight, a title in sentence case, one sentence, and at most one action. `StateView.loading` has a spinner where the symbol is. `StateBar` is the same in one line, for a bar of the window, a card or the chat.

| Screen | State | Symbol | Action |
|---|---|---|---|
| Downloads | Loading | spinner | none |
| Downloads | Folder is empty | `folder` | none |
| Downloads | No matching files (a filter) | `line.3.horizontal.decrease.circle` | none |
| Downloads | The folder can't be read | `exclamationmark.triangle` | Try again |
| Downloads | Access is blocked | `lock` | Open privacy settings |
| Activity | Loading | spinner | none |
| Activity | No activity yet | `clock` | none |
| Activity | The log can't be used | `exclamationmark.triangle` | in the bar below |
| Preview, Tidy Now | Nothing to clean up | `checkmark.circle` | none (Done is in the footer) |
| Preview | Old downloads can't be used | `exclamationmark.triangle` | none |
| Chat bar | Apple Intelligence is unavailable | `sparkles` | Open System Settings, Open Settings, or none |

- Do: keep the surrounding frame (bars, toolbar) in place, and say what would be here or what to do.
- Do: when the one action leaves the app (the privacy settings), look again when the app comes back to the front, so no second button is needed.
- Do not: illustrate it, use a filled symbol, add an exclamation mark, or offer a button that leads nowhere new. An empty folder and an empty Activity have no next step, so they have no button.
- The one exception: the activity log's bar has two buttons, Try again and Start a fresh log. Both are real ways out, and the second sets the damaged file aside.

### First run

`WelcomeSheet`, a small sheet over the main window, once: what the app does in three lines, the promise in four (a preview first, the Trash, undo, nothing leaves the Mac), one button. The folder is read when it closes, so the Mac's question about Downloads comes after the promise. `FirstRun` (in `FileStoreCore`, with its tests) keeps whether it was shown.

- Do not: add a tour, a second page, a sign-up or a setting to show it again.

### Bars

Filter bar, progress line, notices and status bar share `.barInset()` (12 across, 4 down) and the `secondary` role, with a `Divider()` between bars. The filter is a segmented control while it fits, and a pop-up menu when the window is narrow.

## Copy

- Sentence case for everything in a window or sheet: titles, buttons, column headings, badges, empty states. "Tidy now", "Date added", "No matching files". The one exception is a sheet or a run named after a command, which carries the command's name ("Tidy Now", "Find Duplicates").
- Menus keep the Mac's Title Case: the menu bar, the toolbar's Clean up menu and context menus. A command has one name wherever it is a menu item ("Remove Used Installers", "Reveal in Finder"), and prose that points at a menu uses that name ("Clean Up > Tidy Now").
- Names keep their capitals: Trash, Finder, Downloads, Quick Look, Apple Intelligence, System Settings, Activity, and the marks when named in a sentence (Kept, Never opened). The archive folder is always "Old downloads".
- Short and specific: say what happened and to how many ("3 files moved to the Trash"), never "Success". An error says what to do next.
- No exclamation marks, no emoji, no "please", no "simply".
- One word for one thing:
  - **Trash**: "the Trash" in a sentence; "Move to Trash" is the command. A file comes back "put back from the Trash".
  - **Kept**: the mark the user gives a file, and nothing else. The copy a group of duplicates leaves is the copy that "stays" (its badge is "Stays"); a log file set aside is "saved".
  - **cleanup**: one run of a command, Tidy Now's included; always with its article ("the cleanup stopped"). "Clean up" is the verb.
  - **tick**: a checkbox is ticked ("Tick all", "6 of 6 files ticked"). "Selected" is for highlighted rows only.
  - **Stop** ends work in progress, **Cancel** leaves before anything started, **Done** closes a result, **Close** closes a sheet that only shows something.
  - **listed**: the folder is "listed" ("changed since the folder was listed"), and "Refresh" lists it again.
  - "Reveal in Finder" (not Show).
- A reason that is a full sentence ends with a full stop. A status of a few words ("Stopped", "Moved to the Trash", "Already undone") does not.
- A count that may be one is inflected (`^[\(n) file](inflect: true)`), and the words around it must read right for one and for many.

## Window

Default 1,280 × 720: the six columns at their ideal widths beside the sidebar. Minimum 720 × 480 for the part beside the sidebar. Narrower than the ideal, the table scrolls sideways, the filter becomes a menu, and the toolbar moves what does not fit into its overflow menu, Refresh first and Tidy now last. macOS remembers the window's size and the sidebar's width; the app adds no code for it.

## Checking a change

1. `DesignTokenTests` passes (it runs with the other tests).
2. Look at the screen in light mode, dark mode and with Increase Contrast, at the default and the minimum window size.
3. Turn on Reduce Motion: nothing should slide or fade.
4. VoiceOver reads every control with a label, and every row in one go.
