import FileStoreCore
import QuickLook
import SwiftUI

/// The preview of a cleanup plan: what stays, what would change and why. A plan of duplicates is
/// shown by group with its kept copy, a plan of near-duplicates by group with nothing ticked; any
/// other plan one change per row, with the new name or folder for a rename or a move. Every
/// proposed change has a checkbox, which Space toggles for the selected row; Command-Y opens Quick
/// Look, and Space with two rows selected shows them side by side. Keep This File, in the context menu or with Command-K,
/// takes the selected change out of the plan and marks its file Kept. Move to Trash or Rename asks for confirmation, carries
/// out the ticked changes and then shows what happened; moves are shown but not applied yet.
/// Every cleanup action shares this screen.
struct CleanupPreviewSheet: View {
    @State private var model: CleanupPreviewModel
    @State private var selection: Set<URL> = []
    @State private var previewItem: URL?

    /// The two files shown side by side, while they are.
    @State private var comparing: [FileRecord]?

    /// The checkbox with keyboard focus, if any. It owns Space itself; the list's handler stands back.
    @FocusState private var focusedCheckbox: URL?

    @Environment(\.dismiss) private var dismiss

    /// Catches Command-A while the sheet is up. A list takes Command-A as the standard Select All
    /// before any button's shortcut is considered, so without this the shortcut would select the
    /// list's rows (nothing visible) instead of ticking every duplicate.
    @State private var selectAllMonitor: SelectAllKeyMonitor?

    /// The summary's Undo: asks the main window to undo the run just shown, once this sheet is closed.
    private let onUndo: (@MainActor (ActivityRun.ID) -> Void)?

    init(
        plan: CleanupPlan,
        eligibility: CandidateEligibility,
        applicationFolders: [URL],
        log: ActivityLog,
        activity: ActivityLogModel,
        markKept: @escaping @MainActor ([FileRecord], @escaping @MainActor (Bool) -> Void) -> Void,
        onUndo: (@MainActor (ActivityRun.ID) -> Void)? = nil,
        onExecuted: @escaping @MainActor (CleanupResult) -> Void
    ) {
        self.onUndo = onUndo
        _model = State(
            initialValue: CleanupPreviewModel(
                plan: plan,
                eligibility: eligibility,
                applicationFolders: applicationFolders,
                log: log,
                activity: activity,
                markKept: markKept,
                onExecuted: onExecuted
            )
        )
    }

    private var plan: CleanupPlan { model.plan }

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(16)
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            footer
                .padding(12)
        }
        .frame(minWidth: 620, idealWidth: 700, minHeight: 420, idealHeight: 540)
        .sheet(item: Binding(
            get: { comparing.map(ComparedFiles.init) },
            set: { comparing = $0?.records }
        )) { compared in
            CompareFilesSheet(records: compared.records)
        }
        .sheet(isPresented: $model.isConfirming) {
            CleanupConfirmationSheet(
                operation: model.operation,
                fileCount: model.tickedCount,
                bytes: model.tickedBytes,
                trashCount: tickedTrash.count,
                trashBytes: tickedTrash.reduce(0) { $0 + $1.sizeInBytes }
            ) {
                model.execute()
            }
        }
        .interactiveDismissDisabled(model.isExecuting)
        .onExitCommand {
            // Escape closes the sheet, except while files are being moved.
            if !model.isExecuting {
                close()
            }
        }
        .onAppear {
            selectAllMonitor = SelectAllKeyMonitor { [model] in
                // Only while reviewing, and not while the confirmation or Quick Look is in front.
                guard model.isReviewing, !model.isConfirming, previewItem == nil, comparing == nil else { return false }
                model.selectAll()
                return true
            }
        }
        .onDisappear {
            selectAllMonitor = nil
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(plan.action.title)
                .font(.title2.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
            if plan.archiveProblem != nil {
                Text("Nothing was archived")
                    .foregroundStyle(.secondary)
            } else if plan.isEmpty, model.keptCount > 0 {
                Text("^[\(model.keptCount) file](inflect: true) kept")
                    .foregroundStyle(.secondary)
            } else if plan.isEmpty {
                Text(plan.action.display.emptyTitle)
                    .foregroundStyle(.secondary)
            } else if model.result == nil {
                // Once files have moved, the summary below says what happened instead.
                if model.isGroupedByNearDuplicates {
                    Text("^[\(plan.changes.count) file](inflect: true) in ^[\(plan.nearDuplicateGroups.count) group](inflect: true) share a name but not their content. Nothing is ticked: tick only what you want in the Trash.")
                        .foregroundStyle(.secondary)
                } else if plan.action == .reviewLargeDownloads {
                    Text("^[\(plan.changes.count) item](inflect: true), largest first. Nothing is ticked: tick only what you want in the Trash.")
                        .foregroundStyle(.secondary)
                } else if model.isGroupedByDuplicates {
                    Text("^[\(plan.changes.count) duplicate](inflect: true) in ^[\(plan.duplicateGroups.count) group](inflect: true) would free \(plan.bytesToFree.formattedFileSize)")
                        .foregroundStyle(.secondary)
                } else if plan.bytesToFree > 0 {
                    Text("^[\(plan.changes.count) change](inflect: true) would free \(plan.bytesToFree.formattedFileSize)")
                        .foregroundStyle(.secondary)
                } else {
                    Text("^[\(plan.changes.count) change](inflect: true)")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var content: some View {
        if let result = model.result {
            CleanupSummaryView(result: result)
        } else if let problem = plan.archiveProblem {
            ContentUnavailableView(
                "Old downloads Can’t Be Used",
                systemImage: "exclamationmark.triangle",
                description: Text(problem.localizedDescription)
            )
        } else if plan.isEmpty, plan.skippedItems.isEmpty, model.keptCount > 0 {
            ContentUnavailableView(
                "Nothing Left to Clean Up",
                systemImage: "checkmark.circle",
                description: Text("You kept every file this cleanup proposed.")
            )
        } else if plan.isEmpty, plan.skippedItems.isEmpty {
            ContentUnavailableView(
                plan.action.display.emptyTitle,
                systemImage: "checkmark.circle",
                description: Text(plan.action.display.emptyDescription)
            )
        } else {
            changeList
        }
    }

    private var changeList: some View {
        List(selection: $selection) {
            if model.isGroupedByNearDuplicates {
                ForEach(plan.nearDuplicateGroups) { group in
                    let newest = group.newestIDs
                    let largest = group.largestIDs
                    Section {
                        ForEach(group.members) { member in
                            NearDuplicateRow(
                                member: member,
                                reason: reason(for: member.id),
                                isNewest: newest.contains(member.id),
                                isLargest: largest.contains(member.id),
                                isTicked: tickedBinding(member.id),
                                canTick: model.canTick(member.id),
                                isEnabled: model.isReviewing,
                                focusedCheckbox: $focusedCheckbox
                            )
                            .tag(member.id)
                        }
                    } header: {
                        Text(group.cleanedName)
                    } footer: {
                        Text("One file of each group always stays, so the last one can’t be ticked.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } else if model.isGroupedByDuplicates {
                ForEach(plan.duplicateGroups) { group in
                    Section {
                        KeptFileRow(record: group.kept)
                            .tag(group.kept.url)
                        ForEach(group.duplicates) { record in
                            DuplicateFileRow(
                                record: record,
                                sizeInBytes: group.fileSizeInBytes,
                                reason: .sameContent(asFileNamed: group.kept.displayName),
                                isTicked: tickedBinding(record.id),
                                isEnabled: model.isReviewing,
                                focusedCheckbox: $focusedCheckbox
                            )
                            .tag(record.url)
                        }
                    }
                }
            } else if plan.action == .reviewLargeDownloads {
                Section {
                    ForEach(plan.changes) { change in
                        LargeDownloadRow(
                            change: change,
                            isTicked: tickedBinding(change.id),
                            isEnabled: model.isReviewing,
                            focusedCheckbox: $focusedCheckbox
                        )
                        .tag(change.id)
                    }
                }
            } else {
                Section {
                    ForEach(plan.changes) { change in
                        ChangeRow(
                            change: change,
                            folderURL: plan.folderURL,
                            isTicked: tickedBinding(change.id),
                            isEnabled: model.isReviewing,
                            focusedCheckbox: $focusedCheckbox
                        )
                        .tag(change.id)
                    }
                }
            }
            if !plan.skippedItems.isEmpty {
                Section("Not Checked") {
                    ForEach(plan.skippedItems) { item in
                        SkippedFileRow(item: item, action: plan.action)
                    }
                }
            }
        }
        .contextMenu(forSelectionType: URL.self) { urls in
            Button("Quick Look") {
                preview(urls)
            }
            Divider()
            // Proposed rows only: the copy a group keeps and the unchecked files are not in the plan.
            Button("Keep This File") {
                model.keep(urls)
            }
            .disabled(!model.canKeep(urls))
        } primaryAction: { urls in
            preview(urls)
        }
        .onKeyPress(.space) {
            // A focused checkbox owns Space. With two rows selected, Space shows them side by side.
            // Otherwise Space ticks or unticks the selected change; kept and unchecked rows have no
            // checkbox, so Space does nothing on them.
            guard focusedCheckbox == nil else { return .ignored }
            if selection.count == 2 {
                let records = rowRecords.filter { selection.contains($0.id) }
                guard records.count == 2 else { return .ignored }
                previewItem = nil
                comparing = records
                return .handled
            }
            guard model.isReviewing, let selectedRow,
                  let id = changeID(for: selectedRow) else { return .ignored }
            model.setTicked(id, !model.isTicked(id))
            return .handled
        }
        .onKeyPress(phases: .down) { press in
            guard press.modifiers == .command else { return .ignored }
            switch press.key {
            case "y":
                // Command-Y, as in Finder, handled by the list itself.
                guard !selection.isEmpty || previewItem != nil else { return .ignored }
                toggleQuickLook()
                return .handled
            case "k":
                // Command-K, as in the main window: Keep This File for the selected rows.
                guard model.canKeep(selection) else { return .ignored }
                model.keep(selection)
                return .handled
            default:
                return .ignored
            }
        }
        .onKeyPress(.return) {
            // A list answers Return with its primary action (Quick Look) before the default button
            // is considered; here Return means the default button. That is Move to Trash or Rename,
            // which only opens the confirmation, or Done for a plan that is previewed only.
            if model.isReviewing, !model.canBeApplied {
                close()
                return .handled
            }
            guard model.canExecute, !model.isConfirming else { return .ignored }
            confirm()
            return .handled
        }
        .quickLookPreview($previewItem, in: rowURLs)
        .accessibilityLabel(
            model.isGroupedByNearDuplicates
                ? Text("Near-duplicate groups")
                : model.isGroupedByDuplicates ? Text("Duplicate groups") : Text("Proposed changes")
        )
    }

    /// The one selected row, if exactly one is selected.
    private var selectedRow: URL? {
        selection.count == 1 ? selection.first : nil
    }

    /// The reason the plan gives for the change on row `id`.
    private func reason(for id: ProposedChange.ID) -> ProposedChange.Reason {
        plan.changes.first { $0.id == id }?.reason ?? .nearDuplicate(sameNameAs: "")
    }

    /// The proposed change shown in the row tagged `row`, if that row is one.
    private func changeID(for row: URL) -> ProposedChange.ID? {
        plan.changes.contains { $0.id == row } ? row : nil
    }

    /// Opens Quick Look for the selected row, or closes it when it is showing: the panel sets the
    /// binding back to nil when it closes.
    private func toggleQuickLook() {
        if previewItem != nil {
            previewItem = nil
            return
        }
        guard !selection.isEmpty else { return }
        preview(selection)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if model.isReviewing, let share = plan.largeDownloadsShare {
                Text("These take up \(share.listed.formattedFileSize) on disk, \(share.fraction.formatted(.percent.precision(.fractionLength(0)))) of the \(share.total.formattedFileSize) taken by the files at the top of this folder.")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            footerControls
        }
    }

    @ViewBuilder
    private var footerControls: some View {
        switch model.phase {
        case .reviewing where plan.isEmpty:
            HStack {
                skippedNote
                Spacer()
                doneButton
            }
        case .reviewing where model.canBeApplied:
            HStack(spacing: 12) {
                selectButtons
                Group {
                    if model.operation == .rename {
                        Text("^[\(model.tickedCount) file](inflect: true) selected")
                    } else {
                        Text("^[\(model.tickedCount) file](inflect: true) (\(model.tickedBytes.formattedFileSize)) selected")
                    }
                }
                .monospacedDigit()
                .foregroundStyle(.secondary)
                skippedNote
                Spacer()
                Button("Cancel") {
                    close()
                }
                .keyboardShortcut(.cancelAction)
                Button {
                    confirm()
                } label: {
                    switch model.operation {
                    case .rename:
                        Text("Rename")
                    case .archive:
                        Text("Archive")
                    case .moveToTrash, .move:
                        Text("Move to Trash")
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!model.canExecute || model.isConfirming)
            }
        case .reviewing:
            // A plan with a change its action may not make: previewed only, and Done closes.
            HStack(spacing: 12) {
                selectButtons
                Text("^[\(model.tickedCount) change](inflect: true) selected")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                skippedNote
                Spacer()
                doneButton
            }
        case .executing(let progress):
            HStack(spacing: 12) {
                let current = min(progress.itemsCompleted + 1, progress.itemsTotal)
                ProgressView(value: progress.fractionCompleted)
                    .frame(maxWidth: 240)
                    .accessibilityLabel(progressLabel)
                progressText(current: current, total: progress.itemsTotal)
                    .monospacedDigit()
                Spacer()
            }
        case .finished(let result):
            HStack {
                if !result.leftAlone.isEmpty {
                    Group {
                        if model.operation == .rename {
                            Text("^[\(result.leftAlone.count) file](inflect: true) not renamed")
                        } else {
                            Text("^[\(result.leftAlone.count) file](inflect: true) not moved")
                        }
                    }
                    .foregroundStyle(.secondary)
                }
                Spacer()
                if let onUndo, let runID = result.runID, result.hasDoneItems, result.logFailure == nil {
                    Button("Undo") {
                        onUndo(runID)
                        close()
                    }
                    .help(model.operation == .rename ? Text("Give the files their old names back") : Text("Put the files back where they were"))
                }
                doneButton
            }
        }
    }

    /// The ticked changes that go to the Trash: for Archive Old Downloads, the identical copies.
    private var tickedTrash: [ProposedChange] {
        model.tickedChanges.filter { $0.operation == .moveToTrash }
    }

    private var progressLabel: Text {
        switch model.operation {
        case .rename:
            Text("Progress renaming files")
        case .archive:
            Text("Progress archiving files")
        case .moveToTrash, .move:
            Text("Progress moving files to the Trash")
        }
    }

    private func progressText(current: Int, total: Int) -> Text {
        switch model.operation {
        case .rename:
            Text("Renaming file \(current) of \(total)…")
        case .archive:
            Text("Archiving file \(current) of \(total)…")
        case .moveToTrash, .move:
            Text("Moving file \(current) of \(total) to the Trash…")
        }
    }

    /// Select All and Select None, worded for duplicates or for changes.
    @ViewBuilder
    private var selectButtons: some View {
        // Near-duplicates and large downloads are ticked one by one, after looking: Select All would
        // tick none of them.
        if !plan.changes.contains(where: \.reason.isReviewOnly) {
            Button("Select All") {
                model.selectAll()
            }
            .keyboardShortcut("a", modifiers: .command)
            .help(model.isGroupedByDuplicates ? Text("Tick every duplicate (⌘A)") : Text("Tick every change (⌘A)"))
        }
        Button("Select None") {
            model.selectNone()
        }
        // Finder's shortcut for Deselect All. Shift-Command-A shows Activity.
        .keyboardShortcut("a", modifiers: [.command, .option])
        .help(model.isGroupedByDuplicates ? Text("Untick every duplicate (⌥⌘A)") : Text("Untick every change (⌥⌘A)"))
    }

    @ViewBuilder
    private var skippedNote: some View {
        if model.keepFailed {
            Text("Couldn’t mark files Kept: the activity log stopped working.")
                .foregroundStyle(.secondary)
        }
        if !plan.skippedItems.isEmpty {
            Text("^[\(plan.skippedItems.count) file](inflect: true) could not be checked")
                .foregroundStyle(.secondary)
        }
    }

    private var doneButton: some View {
        Button("Done") {
            close()
        }
        .keyboardShortcut(.defaultAction)
    }

    /// Every row's URL in display order, so the Quick Look panel's arrows move through the list.
    private var rowURLs: [URL] {
        rowRecords.map(\.url)
    }

    /// Every row's file in display order.
    private var rowRecords: [FileRecord] {
        if model.isGroupedByNearDuplicates {
            return plan.nearDuplicateGroups.flatMap { $0.members.map(\.record) }
        }
        guard model.isGroupedByDuplicates else {
            return plan.changes.map(\.record)
        }
        return plan.duplicateGroups.flatMap { group in
            [group.kept] + group.duplicates
        }
    }

    private func preview(_ urls: Set<URL>) {
        guard let first = rowURLs.first(where: { urls.contains($0) }) else { return }
        previewItem = first
    }

    private func tickedBinding(_ id: ProposedChange.ID) -> Binding<Bool> {
        Binding(
            get: { model.isTicked(id) },
            set: { model.setTicked(id, $0) }
        )
    }

    /// Asks before anything changes; `CleanupConfirmationSheet` calls `execute` only from its
    /// Move to Trash or Rename button. Quick Look closes first so its panel does not float over the question.
    private func confirm() {
        guard model.canExecute, !model.isConfirming else { return }
        previewItem = nil
        model.isConfirming = true
    }

    private func close() {
        previewItem = nil
        dismiss()
    }
}

/// The files of a side-by-side comparison, as a sheet's item.
private struct ComparedFiles: Identifiable {
    let records: [FileRecord]

    var id: [URL] { records.map(\.id) }
}
