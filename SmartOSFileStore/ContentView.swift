import FileStoreCore
import SwiftUI

/// The main window: the file table with its toolbar and status line, or the loading, empty and
/// error states in its place.
struct ContentView: View {
    @Environment(ActivityLogModel.self) private var activity
    @State private var model = FileListModel()
    @State private var duplicates = DuplicateSearchModel()
    @State private var selection: Set<FileRecord.ID> = []

    var body: some View {
        VStack(spacing: 0) {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if let progress = duplicates.progress {
                Divider()
                DuplicateProgressView(progress: progress, cancel: duplicates.cancel)
            }
            ActivityLogNotices(activity: activity)
            Divider()
            StatusBar(model: model, activity: activity)
        }
        // Wide enough for all six columns at their ideal widths, so the table never has to
        // scroll sideways in a window the user has not resized.
        .frame(minWidth: 1_080, minHeight: 400)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    findDuplicates()
                } label: {
                    Label("Find Duplicates", systemImage: "doc.on.doc")
                }
                .keyboardShortcut("d", modifiers: [.command, .shift])
                .help(
                    activity.failure == nil
                        ? Text("Find files with identical content (⇧⌘D)")
                        : Text("Nothing can be cleaned up until the activity log works")
                )
                .disabled(!canFindDuplicates)
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    model.refresh()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .keyboardShortcut("r", modifiers: .command)
                .help("Refresh the list (⌘R)")
                .disabled(!model.canRefresh)
            }
        }
        .sheet(item: presentedPlan) { presented in
            PresentedPlanSheet(plan: presented.plan, eligibility: model.eligibility, activity: activity) {
                // Files moved, so the rows on screen are stale.
                model.refresh()
            }
            // A later plan must start with its own ticks and its own log, never an earlier sheet's.
            .id(presented.id)
        }
        // While a preview sheet is up, menu commands must not act on the table behind it.
        .focusedSceneValue(\.selectedFileURLs, duplicates.presentedPlan == nil ? Array(selection) : nil)
        .focusedSceneValue(\.selectedDownloadAddresses, duplicates.presentedPlan == nil ? model.downloadAddresses(for: selection) : nil)
        .focusedSceneValue(\.fileListFilter, $model.filter)
        #if DEBUG
        .focusedSceneValue(\.duplicateSearch, duplicates)
        #endif
        .onAppear {
            activity.open()
            model.refresh()
        }
        .onChange(of: model.isLoading) { _, isLoading in
            // A refresh replaces the rows a running search was given, so its plan would describe
            // files the table no longer shows. Stop it; the user can run it again on the new list.
            if isLoading, duplicates.isRunning {
                duplicates.cancel()
            }
        }
        .onChange(of: model.scanGeneration) {
            // The listing was replaced: drop selected rows that are gone, so menu commands never
            // act on files that are no longer listed, and forget per-file icons.
            keepSelectionVisible()
            FileIconCache.shared.removeAll()
        }
        .onChange(of: model.filter) {
            // Rows the filter hides must not stay selected, or menu commands would act on them.
            keepSelectionVisible()
        }
    }

    /// Duplicates are found among every listed file, whatever the filter shows (the preview names
    /// each file it proposes), so the list must be settled first, and a new search must never
    /// replace a preview the user is still looking at. Without a working activity log nothing may
    /// be cleaned up, so nothing is searched for either.
    private var canFindDuplicates: Bool {
        model.isSettled && !duplicates.isRunning && duplicates.presentedPlan == nil && activity.log != nil
    }

    /// `.sheet(item:)` keeps showing the plan while the sheet animates away; setting it to nil
    /// is how the sheet reports that it was dismissed.
    private var presentedPlan: Binding<DuplicateSearchModel.PresentedPlan?> {
        Binding(
            get: { duplicates.presentedPlan },
            set: { presented in
                if presented == nil {
                    duplicates.dismissPlan()
                }
            }
        )
    }

    private func keepSelectionVisible() {
        selection = selection.intersection(Set(model.visibleRecords.map(\.id)))
    }

    private func findDuplicates() {
        guard let location = model.location else { return }
        duplicates.start(records: model.records, folderURL: location.folderURL, eligibility: model.eligibility)
    }

    @ViewBuilder
    private var content: some View {
        if let failure = model.failure {
            ScanErrorView(failure: failure, retry: model.canRefresh ? model.refresh : nil)
        } else if !model.hasLoadedOnce {
            ProgressView("Loading…")
                .controlSize(.large)
        } else if model.isEmpty {
            ContentUnavailableView(
                "Folder Is Empty",
                systemImage: "folder",
                description: Text("There are no files in this folder.")
            )
        } else {
            VStack(spacing: 0) {
                FileFilterBar(filter: $model.filter)
                Divider()
                FileTableView(model: model, selection: $selection)
            }
        }
    }
}

/// The sheet for one presented plan: its preview, with the activity log as it was when the plan was
/// presented. Read live, a log that failed during the run would swap the summary for the notice
/// below, and one that came back would rebuild the preview of a plan already carried out, with
/// every change ticked again.
private struct PresentedPlanSheet: View {
    let plan: CleanupPlan
    let eligibility: CandidateEligibility
    let activity: ActivityLogModel
    let onExecuted: @MainActor () -> Void

    @State private var log: ActivityLog?

    init(plan: CleanupPlan, eligibility: CandidateEligibility, activity: ActivityLogModel, onExecuted: @escaping @MainActor () -> Void) {
        self.plan = plan
        self.eligibility = eligibility
        self.activity = activity
        self.onExecuted = onExecuted
        _log = State(initialValue: activity.log)
    }

    var body: some View {
        if let log {
            CleanupPreviewSheet(plan: plan, eligibility: eligibility, log: log, activity: activity) { _ in
                onExecuted()
            }
        } else {
            // The log stopped working between the search and its preview: nothing may be carried
            // out, so there is nothing to preview.
            ActivityLogUnavailableSheet(activity: activity)
        }
    }
}
