# 0028. Each folder chooses its cleanups

Date: 2026-11-21

## Decision

A `FolderRules` value per managed folder: the actions offered there, which of them Tidy Now runs, whether a preview ticks anything (`ticksByDefault`), and optional thresholds of its own (unused after, old after, large from). It travels on `ManagedFolder.rules`, so every planner call already has it, and is stored in the activity log as JSON in a new `folders.rules` column (migration `v8`; NULL means the kind's defaults). Rule changes are not disk changes and are not recorded in Activity.

Defaults, in code (`FolderRules.defaults(for:)`) and tested (`FolderRulesTests.theDefaultsAreTheTable`):

| Folder | Offered | In Tidy Now | Ticks in previews |
|---|---|---|---|
| Downloads | every action | every action | yes |
| Desktop | every action but Archive Old Downloads | Find Duplicates, Fix Messy Names, Review Near-Duplicates, Review Large Downloads, Remove Empty Folders | yes |
| Documents | Find Duplicates, Review Near-Duplicates, Review Large Downloads, Remove Empty Folders | none (Tidy Now off until turned on) | no |
| Custom | as Documents | none | no |

The plan's table was kept as written. Desktop's Tidy Now includes the two review lists because in Tidy Now they tick nothing anyway, as in Downloads. Documents offers no action that removes a file because of its age: Archive Old Downloads is the only one that plans by age.

- **Enforcement where plans are made.** `CleanupPlanners.plan` returns nil for an action the folder does not offer, and applies the folder's thresholds over the global settings. `TidyNowPlanner` keeps only offered actions, and with no actions given runs the folder's Tidy Now actions. So the toolbar, the Clean Up menu, Tidy Now and the chat all go through the same gate. One test per action per folder kind (`aDisabledActionCannotBePlannedFromAnyEntryPoint`).
- **Ticks.** `CleanupPlan.defaultTickedIDs` is the only source of a preview's default ticks (single previews, Tidy Now, chat cards). It is empty in a folder that does not tick. Select All stays a user action and still ticks. A test runs every planner on the fixture under Documents' tick rule.
- **Archive.** Archive Old Downloads keeps its meaning for Downloads only; nothing moves between managed folders.
- **Kept stays global.**
- **Settings > Folders.** Pick a folder; per action, Offered and In Tidy now; Tick files in previews; the three thresholds as "Same as General" or a value; Reset to Defaults. The toolbar and the Clean Up menu list only the actions offered for the folder on screen; Tidy Now is greyed out where the folder runs none.

## Alternatives

- **A separate `folderRules` table.** One nullable column on `folders` is enough: rules belong to exactly one folder and go when it does.
- **Passing rules to every planner as a parameter.** Rejected: dozens of call sites, and a caller could pass the wrong folder's rules. On the folder they cannot be separated.
- **Filtering only in the UI.** Rejected by the plan: the chat would bypass it.

## Not verified

- The Settings pane on screen (checked only by build and off-screen pictures of the main window).
