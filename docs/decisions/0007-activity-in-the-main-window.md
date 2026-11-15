# 0007. Activity in the main window's sidebar

Date: 2026-11-14 · Segment: version 0.2, segment 4, follow-up (owner's review)

## Decision

The main window has a sidebar with two places, Downloads and Activity, and shows the chosen one beside it (`NavigationSplitView`). Activity is no longer a window of its own. View > Downloads and View > Activity (⇧⌘A) switch places and give the place's list keyboard focus; clicking or arrowing through the sidebar switches places and leaves focus in the sidebar. View > Show/Hide Sidebar (⌃⌘S) is SwiftUI's own.

Both places stay alive while the window is open. The one not shown is invisible and takes no clicks, no keyboard focus and no VoiceOver attention, so each keeps its scroll position, column widths, selection and open cleanups. Quick Look closes when Downloads is hidden. The toolbar, the duplicate search's progress, the activity log's notices and the status line are shared; ⌘R refreshes the place on screen, and the item counts in the status line show in Downloads only. Activity reads the log again each time it is shown, after every cleanup, and on ⌘R; a cleanup's items are read each time it is opened. Everything Activity read starts over whenever a log is opened (Try Again, Start a Fresh Log), since a fresh log numbers its cleanups from 1 again. While the log cannot be used, Activity names the problem in one line and the banner below offers the ways out, as in Downloads.

## Alternatives

- A separate Activity window from the Window menu (what segment 4 first shipped): the owner rejected windows that pop up on their own and places reachable only through a menu or a shortcut.
- Two tabs in the toolbar (Files, Activity): no width taken, but crowded once Large Downloads, Empty Folders and Tidy Now arrive.
- A panel on the right of the file list: files and activity side by side, but both narrower.

## Why

The owner's choice, from mock-ups of the three layouts. The app is to replace Finder, whose sidebar lists places in the same way, and the rest of version 0.2 (the two review lists and Tidy Now) can become rows of this sidebar without another redesign.

## Consequences

- The window's default width grows by the sidebar's (1,320 points instead of 1,140); the file table keeps its minimum of 1,080. The sidebar can be hidden (View > Hide Sidebar), which gives the old width back.
- Commands follow the place on screen: Reveal in Finder acts on the selected files or the selected cleanup items, and the filter and Copy Download Source only on Downloads. While a preview sheet is up, switching places is off, like every command that acts on the window behind it.
- A cleanup's files are rows of their own under it, shown and hidden by its arrow, a double-click, Return, → and ←. They are not a SwiftUI `DisclosureGroup`: measured in an offscreen copy of the view, a List's outline loses track of a group whose rows change while it is open (the files arrive after a loading row) and then never closes it, or raises an exception when told to.
- Each new place is a case of `SidebarSection`, a view in `ContentView`'s detail, and its targets in `publishingCommandTargets`.
- The hidden place keeps its memory and its updates: a new scan still refreshes the hidden table, and a finished cleanup still reloads the hidden Activity list. Both are small next to what the shown place does.
- With one window scene again, closing the main window quits the app, as in version 0.1.
- The owner wants each entry to open to further details later, perhaps with an Apple Intelligence summary. Each file is already a row of its own with its identifier, so a detail view can open from a selected row without changing the list.
