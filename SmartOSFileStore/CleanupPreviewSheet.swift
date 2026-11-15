import FileStoreCore
import QuickLook
import SwiftUI

/// The preview of a cleanup plan: what stays, what would change and why. A plan of duplicates is
/// shown by group with its kept copy; any other plan one change per row, with the new name or
/// folder for a rename or a move. Every proposed change has a checkbox, which Space toggles for the
/// selected row; Command-Y opens Quick Look. Move to Trash asks for confirmation, carries out the
/// ticked changes and then shows what happened; renames and moves are shown but not applied yet.
/// Every cleanup action shares this screen.
struct CleanupPreviewSheet: View {
    @State private var model: CleanupPreviewModel
    @State private var selectedRow: URL?
    @State private var previewItem: URL?

    /// The checkbox with keyboard focus, if any. It owns Space itself; the list's handler stands back.
    @FocusState private var focusedCheckbox: URL?

    @Environment(\.dismiss) private var dismiss

    /// Catches Command-A while the sheet is up. A list takes Command-A as the standard Select All
    /// before any button's shortcut is considered, so without this the shortcut would select the
    /// list's rows (nothing visible) instead of ticking every duplicate.
    @State private var selectAllMonitor: SelectAllKeyMonitor?

    init(
        plan: CleanupPlan,
        eligibility: CandidateEligibility,
        log: ActivityLog,
        activity: ActivityLogModel,
        onExecuted: @escaping @MainActor (CleanupResult) -> Void
    ) {
        _model = State(
            initialValue: CleanupPreviewModel(plan: plan, eligibility: eligibility, log: log, activity: activity, onExecuted: onExecuted)
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
        .sheet(isPresented: $model.isConfirming) {
            TrashConfirmationSheet(fileCount: model.tickedCount, bytes: model.tickedBytes) {
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
                guard model.isReviewing, !model.isConfirming, previewItem == nil else { return false }
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
            if plan.isEmpty {
                Text(plan.action.emptyTitle)
                    .foregroundStyle(.secondary)
            } else if model.result == nil {
                // Once files have moved, the summary below says what happened instead.
                if model.isGroupedByDuplicates {
                    Text("^[\(plan.changes.count) duplicate](inflect: true) in ^[\(plan.duplicateGroups.count) group](inflect: true) would free \(plan.bytesToFree.formattedFileSize)")
                        .foregroundStyle(.secondary)
                } else if plan.bytesToFree > 0 {
                    Text("^[\(plan.changes.count) change](inflect: true) would free \(plan.bytesToFree.formattedFileSize)")
                        .foregroundStyle(.secondary)
                } else {
                    Text("^[\(plan.changes.count) change](inflect: true)")
                        .foregroundStyle(.secondary)
                }
                if !model.isTrashOnly {
                    Text("Renames and moves can’t be applied yet.")
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
        } else if plan.isEmpty, plan.skippedItems.isEmpty {
            ContentUnavailableView(
                plan.action.emptyTitle,
                systemImage: "checkmark.circle",
                description: Text(plan.action.emptyDescription)
            )
        } else {
            changeList
        }
    }

    private var changeList: some View {
        List(selection: $selectedRow) {
            if model.isGroupedByDuplicates {
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
                        SkippedFileRow(item: item)
                    }
                }
            }
        }
        .contextMenu(forSelectionType: URL.self) { urls in
            Button("Quick Look") {
                preview(urls)
            }
        } primaryAction: { urls in
            preview(urls)
        }
        .onKeyPress(.space) {
            // A focused checkbox owns Space. Otherwise Space ticks or unticks the selected duplicate;
            // kept and unchecked rows have no checkbox, so Space does nothing on them.
            guard focusedCheckbox == nil, model.isReviewing, let selectedRow,
                  let id = changeID(for: selectedRow) else { return .ignored }
            model.setTicked(id, !model.isTicked(id))
            return .handled
        }
        .onKeyPress(phases: .down) { press in
            // Command-Y, as in Finder, handled by the list itself.
            guard press.key == "y", press.modifiers == .command, selectedRow != nil || previewItem != nil else {
                return .ignored
            }
            toggleQuickLook()
            return .handled
        }
        .onKeyPress(.return) {
            // A list answers Return with its primary action (Quick Look) before the default button
            // is considered; here Return means the default button. That is Move to Trash, which
            // only opens the confirmation, or Done for a plan that is previewed only.
            if model.isReviewing, !model.isTrashOnly {
                close()
                return .handled
            }
            guard model.canExecute, !model.isConfirming else { return .ignored }
            confirm()
            return .handled
        }
        .quickLookPreview($previewItem, in: rowURLs)
        .accessibilityLabel(model.isGroupedByDuplicates ? Text("Duplicate groups") : Text("Proposed changes"))
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
        guard let selectedRow else { return }
        preview([selectedRow])
    }

    @ViewBuilder
    private var footer: some View {
        switch model.phase {
        case .reviewing where plan.isEmpty:
            HStack {
                skippedNote
                Spacer()
                doneButton
            }
        case .reviewing where model.isTrashOnly:
            HStack(spacing: 12) {
                selectButtons
                Text("^[\(model.tickedCount) file](inflect: true) (\(model.tickedBytes.formattedFileSize)) selected")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                skippedNote
                Spacer()
                Button("Cancel") {
                    close()
                }
                .keyboardShortcut(.cancelAction)
                Button("Move to Trash") {
                    confirm()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!model.canExecute || model.isConfirming)
            }
        case .reviewing:
            // Renames and moves: previewed only, so there is nothing to apply and Done closes.
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
                ProgressView(value: progress.fractionCompleted)
                    .frame(maxWidth: 240)
                    .accessibilityLabel("Progress moving files to the Trash")
                Text("Moving file \(min(progress.itemsCompleted + 1, progress.itemsTotal)) of \(progress.itemsTotal) to the Trash…")
                    .monospacedDigit()
                Spacer()
            }
        case .finished(let result):
            HStack {
                if !result.leftAlone.isEmpty {
                    Text("^[\(result.leftAlone.count) file](inflect: true) not moved")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                doneButton
            }
        }
    }

    /// Select All and Select None, worded for duplicates or for changes.
    @ViewBuilder
    private var selectButtons: some View {
        Button("Select All") {
            model.selectAll()
        }
        .keyboardShortcut("a", modifiers: .command)
        .help(model.isGroupedByDuplicates ? Text("Tick every duplicate (⌘A)") : Text("Tick every change (⌘A)"))
        Button("Select None") {
            model.selectNone()
        }
        // Finder's shortcut for Deselect All. Shift-Command-A opens the Activity window.
        .keyboardShortcut("a", modifiers: [.command, .option])
        .help(model.isGroupedByDuplicates ? Text("Untick every duplicate (⌥⌘A)") : Text("Untick every change (⌥⌘A)"))
    }

    @ViewBuilder
    private var skippedNote: some View {
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
        guard model.isGroupedByDuplicates else {
            return plan.changes.map(\.record.url)
        }
        return plan.duplicateGroups.flatMap { group in
            [group.kept.url] + group.duplicates.map(\.url)
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

    /// Asks before anything moves; `TrashConfirmationSheet` calls `execute` only from its
    /// Move to Trash button. Quick Look closes first so its panel does not float over the question.
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
