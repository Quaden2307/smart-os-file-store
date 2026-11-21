# 0027. Desktop, Documents and folders you add, in the app

Date: 2026-11-21

## Decision

The sidebar's Folders section lists Downloads, Desktop and Documents, then the folders the user added, then Add folder…. Each folder that is managed and found has its own `FileListModel` (`FolderListsModel`), so its rows, sort, filter, marks and selection stay while another place is shown. Downloads' list is still found without the activity log, so it reads before the log opens; the others are made when the log finds their folder.

- **Turning on.** Desktop and Documents are listed but off (an "Off" badge) until the user turns one on: from its place in the sidebar (a state with one button), its context menu, or the welcome's two checkboxes. Turning one on puts it on the log's list, and the first read of it is what makes macOS ask. Nothing asks at launch. `NSDesktopFolderUsageDescription` and `NSDocumentsFolderUsageDescription` are in `project.yml`.
- **Permission states.** What can be detected: allowed (the folder lists) and denied (reading it fails with `EPERM`, `FolderScanError.accessDenied`), whether denied at the prompt or turned off later in System Settings while the app runs; the next read after that shows the permission state. The state has one button, Open privacy settings (Files & Folders). The folder is read again when the app comes back to the front. What cannot be detected without reading: "not asked yet". The app does not need it: a folder that is off was never read, and turning it on is the moment to ask. There is no public API that reports a folder's TCC state without touching it.
- **Add folder.** A sidebar row, File > Add Folder… (⇧⌘N) and dragging folders from Finder onto the sidebar all go through `FolderRegistry.add(customFolderAt:)`, so `FolderSafetyRules` decides. A refusal is one sentence in an alert (`FolderSafetyRules.Refusal.sentence`). A custom folder can be renamed in the app (`FolderRegistry.setDisplayName`, display name only) and removed from the sidebar (the log keeps its row, so its runs stay in Activity and can still be undone). Desktop and Documents can be turned off the same way. Nothing on disk changes either way.
- **Missing folders.** `FolderRegistry.entries(in:)` lists every folder on the list with where it is or why it cannot be used. A custom folder that cannot be found (an unplugged disk, deleted) stays in the sidebar under its last name with a warning badge and a state that says it comes back by itself. The list is read again when the app comes to the front and when a disk is mounted or unmounted.
- **Activity.** Each run carries its folder's name as a badge, and a folder menu filters the list. Undo works from any place, and refreshes every list after it, since files go back into the run's own folder.
- **Commands.** The toolbar, the Clean Up menu, Keep, Reveal and the status line act on the folder on screen. Activity keeps the last folder shown as the one a cleanup acts on. The chat bar's placeholder names the folder; the chat answers about the folder on screen (across folders is a later segment). View > Ask About Downloads is now Ask About This Folder.
- **Debug only.** `-StartPlace desktop|documents|activity`, `-TurnOnStandardFolders`, and `-SnapshotTo <name>`, which draws the window off screen at 1440 × 900 and prints it as base64 PNG on standard output. That works while the Mac is locked and needs no screen recording permission; the app still writes no file (SafetyTests).

## Alternatives

- **One `FileListModel` that switches folder.** Rejected: each folder's sort, filter and selection would have to be saved and restored by hand, and a switch would scan again.
- **Asking for Desktop and Documents at launch.** Rejected by the plan: the prompt must come when the user asks for the folder.
- **An `NSOpenPanel` call.** SwiftUI's `fileImporter` does the same for folders with less code.
- **Removing a folder with a confirmation.** Not needed: nothing on disk changes, and adding it again gives it a new ID only for a custom folder (its old runs stay undoable under the old one).

## Not verified

- The real macOS prompts for Desktop and Documents, a denial and a change in System Settings: this run used `-DemoHome`, where macOS asks nothing. Listed for a hand check.
- An external disk unplugged and plugged back in. The code path is the same as a deleted folder, which a test covers.
- The look in light and dark mode on screen; the off-screen pictures used for checking render the window without its toolbar.
