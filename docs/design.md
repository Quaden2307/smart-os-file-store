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
| `windowTitle` | 17 pt semibold | The title of a sheet or a result |
| `sectionTitle` | 13 pt semibold | The question of a confirmation, a group's heading |
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
| `xl` | 24 | A confirmation's or a result's padding |

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
| `large` | Large title | The one symbol at the top of a confirmation or a result |

### Sizes: `Design.Size`

`confirmationSheet` 400 · `progressBar` 240 · `sizeColumn` 72 (a size at the end of a row) · `checkbox` 16 (the width the system checkbox takes in a row).

### Motion: `Design.Motion`

| Token | Value | Use |
|---|---|---|
| `quick` | 0.15 s, ease out | A selection, a disclosure arrow, switching place |
| `standard` | 0.25 s, ease in and out | Rows arriving or leaving a short list (a cleanup's files in Activity) |

Always through `.motion(_:value:)`, which animates nothing when Reduce Motion is on. `.animation(` in a view fails the check, and so does a raw curve or duration. `withAnimation` is for the rare change made in code (the conversation scrolling to its end): it takes a token and checks Reduce Motion itself. Do not animate the layout of the file table: with thousands of rows every frame is expensive. Nothing performs an entrance: motion answers something the user did.

### The chat bar: `Design.Chat`

The chat bar was designed before the tokens and keeps its exact look. Its values sit in `Design.Chat`, some of them off the grid (5, 6, 10, 14, 18 and 22 points; radii 14 and 16; a 10 pt caption; its own six animations). This is the one exception. Nothing outside the chat files uses `Design.Chat` (the check fails if one does), and a new chat view uses the main tokens wherever one fits.

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

`Badge(Text("Keep"))`: caption, secondary text, `badgeFill`, radius 4. Custom because the system has no quiet inline tag.

- Do: one or two words that state a fact about the row. The words carry the meaning.
- Do not: colour it, use it as a button, put it above a heading, or rebuild it by hand in a view.

### Card

Padding `m`, an outline of `hairline` at radius `card`, no fill and no shadow. Used for a result inside the conversation.

- Do: use a card only for a self-contained result that sits in a flow of other content.
- Do not: put a card inside a card, or box a region of the window (use `Divider()`).

### Sheet header

Title in `windowTitle` with the header trait, one line under it in `.secondary`, padding `l`, then a `Divider()`. Left-aligned.

- Do: say in the subtitle what is in the list and what will happen, with the numbers.
- Do not: centre it, add a symbol, or repeat the title in the content.

### Primary and secondary buttons

System button styles only.

- Primary: one per window or sheet. In the toolbar it is `.borderedProminent` with its title showing (Tidy now). In a sheet it is the default action (`.keyboardShortcut(.defaultAction)`), which the system fills with the accent.
- Secondary: the default bordered style. In the toolbar, icon only, with a label and a tooltip.
- Destructive: `role: .destructive`. Never the default action without a confirmation that names what goes.
- Do not: two filled buttons side by side, a custom `ButtonStyle`, a tinted secondary button.

### Empty state

`ContentUnavailableView`: a title in sentence case, one outline symbol, one sentence that says what would be here or what to do.

- Do: keep the surrounding frame (bars, toolbar) in place.
- Do not: illustrate it, add an exclamation mark, or leave it without the next step when there is one.

### Bars

Filter bar, progress line, notices and status bar share `.barInset()` (12 across, 4 down) and the `secondary` role, with a `Divider()` between bars. The filter is a segmented control while it fits, and a pop-up menu when the window is narrow.

## Copy

- Sentence case for everything in a window or sheet: titles, buttons, column headings, badges, empty states. "Tidy now", "Date added", "No matching files".
- Menus keep the Mac's Title Case: the menu bar, the toolbar's Clean up menu and context menus. A command has one name wherever it is a menu item ("Remove Used Installers", "Reveal in Finder"), and prose that points at a menu uses that name ("Clean Up > Tidy Now").
- Names keep their capitals: Trash, Finder, Downloads, Quick Look, Apple Intelligence, System Settings, Activity, and the marks when named in a sentence (Kept, Never opened). The archive folder is always "Old downloads".
- Short and specific: say what happened and to how many ("3 files moved to the Trash"), never "Success". An error says what to do next.
- No exclamation marks, no emoji, no "please", no "simply".
- One word for one thing: "Reveal in Finder" (not Show), "Trash" (not Bin), "cleanup" for a run.

## Window

Default 1,280 × 720: the six columns at their ideal widths beside the sidebar. Minimum 720 × 480 for the part beside the sidebar. Narrower than the ideal, the table scrolls sideways, the filter becomes a menu, and the toolbar moves what does not fit into its overflow menu, Refresh first and Tidy now last. macOS remembers the window's size and the sidebar's width; the app adds no code for it.

## Checking a change

1. `DesignTokenTests` passes (it runs with the other tests).
2. Look at the screen in light mode, dark mode and with Increase Contrast, at the default and the minimum window size.
3. Turn on Reduce Motion: nothing should slide or fade.
4. VoiceOver reads every control with a label, and every row in one go.
