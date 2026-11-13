import FileStoreCore
import QuickLook
import SwiftUI

/// The preview of a cleanup plan: what stays, what would change and why. Every proposed change has
/// a checkbox, which Space toggles for the selected row; Command-Y opens Quick Look. Move to Trash
/// asks for confirmation, carries out the ticked changes and then shows what happened. Every
/// cleanup action shares this screen.
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

    init(plan: CleanupPlan, onExecuted: @escaping @MainActor (CleanupResult) -> Void) {
        _model = State(initialValue: CleanupPreviewModel(plan: plan, onExecuted: onExecuted))
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
            Text("Duplicates")
                .font(.title2.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
            if plan.isEmpty {
                Text("No Duplicates Found")
                    .foregroundStyle(.secondary)
            } else if model.result == nil {
                // Once files have moved, the summary below says what happened instead.
                Text("^[\(plan.changes.count) duplicate](inflect: true) in ^[\(plan.duplicateGroups.count) group](inflect: true) would free \(plan.bytesToFree.formattedFileSize)")
                    .foregroundStyle(.secondary)
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
                "No Duplicates Found",
                systemImage: "checkmark.circle",
                description: Text("No two files in this folder have the same content.")
            )
        } else {
            groupList
        }
    }

    private var groupList: some View {
        List(selection: $selectedRow) {
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
            // is considered; here Return means Move to Trash, which only opens the confirmation.
            guard model.canExecute, !model.isConfirming else { return .ignored }
            confirm()
            return .handled
        }
        .quickLookPreview($previewItem, in: rowURLs)
        .accessibilityLabel("Duplicate groups")
    }

    /// The proposed change shown in the row tagged `row`, if that row is a duplicate.
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
        case .reviewing:
            HStack(spacing: 12) {
                Button("Select All") {
                    model.selectAll()
                }
                .keyboardShortcut("a", modifiers: .command)
                .help("Tick every duplicate (⌘A)")
                Button("Select None") {
                    model.selectNone()
                }
                .keyboardShortcut("a", modifiers: [.command, .shift])
                .help("Untick every duplicate (⇧⌘A)")
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
                if !result.notMoved.isEmpty {
                    Text("^[\(result.notMoved.count) file](inflect: true) not moved")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                doneButton
            }
        }
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
        plan.duplicateGroups.flatMap { group in
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

/// The copy that stays, marked Keep. Selectable and previewable like any row, but with no checkbox.
private struct KeptFileRow: View {
    let record: FileRecord

    var body: some View {
        HStack(spacing: 8) {
            // Takes the checkbox's place so the names line up.
            Color.clear
                .frame(width: DuplicateFileRow.checkboxWidth, height: 1)
                .accessibilityHidden(true)
            FileIconView(record: record)
            Text(record.displayName)
                .font(.body)
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.middle)
            Text("Keep")
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .foregroundStyle(.secondary)
                .background(.quaternary, in: Capsule())
            Spacer()
            if let size = record.formattedSize {
                Text(size)
                    .font(.body)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 72, alignment: .trailing)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// A copy proposed for the Trash: its checkbox, name, reason, Date Added and size.
private struct DuplicateFileRow: View {
    /// Width of a regular checkbox, which the kept row leaves blank.
    static let checkboxWidth: CGFloat = 14

    let record: FileRecord
    let sizeInBytes: Int64
    let reason: ProposedChange.Reason
    @Binding var isTicked: Bool
    let isEnabled: Bool
    let focusedCheckbox: FocusState<URL?>.Binding

    var body: some View {
        HStack(spacing: 8) {
            // The label is hidden but still read by VoiceOver.
            Toggle(isOn: $isTicked) {
                Text("Move \(record.displayName) to the Trash")
            }
            .toggleStyle(.checkbox)
            .labelsHidden()
            .disabled(!isEnabled)
            .focused(focusedCheckbox, equals: record.id)
            // One VoiceOver element after the checkbox: name, reason, date and size in one breath.
            HStack(spacing: 8) {
                FileIconView(record: record)
                VStack(alignment: .leading, spacing: 1) {
                    Text(record.displayName)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(reason.localizedDescription)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                DateCell(date: record.dateAdded)
                    .foregroundStyle(.secondary)
                Text(sizeInBytes.formattedFileSize)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 72, alignment: .trailing)
            }
            .accessibilityElement(children: .combine)
        }
    }
}

/// A file the search could not check, and why. It is left alone.
private struct SkippedFileRow: View {
    let item: CleanupPlan.SkippedItem

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(item.url.lastPathComponent)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            Text(item.reason.localizedDescription)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
    }
}
