import FileStoreCore
import SwiftUI

/// The main window: a sidebar of places (Downloads, Activity) and the chosen place beside it, with
/// the toolbar and status line. Downloads is the file table, or the loading, empty and error states
/// in its place; Activity is every confirmed cleanup.
struct ContentView: View {
    @Environment(ActivityLogModel.self) private var activity
    @State private var model = FileListModel()
    @State private var duplicates = DuplicateSearchModel()
    @State private var selection: Set<FileRecord.ID> = []
    @State private var section: SidebarSection = .downloads
    @State private var activityList = ActivityListModel()
    @State private var activitySelection: Set<ActivityRowID> = []

    /// Which place's list has keyboard focus, when the View menu moves it there.
    @FocusState private var focusedPlace: SidebarSection?

    /// The place whose list takes focus once it is shown, after a switch from the View menu.
    @State private var placeToFocus: SidebarSection?

    var body: some View {
        observingChanges(publishingCommandTargets(splitView))
    }

    private var splitView: some View {
        NavigationSplitView {
            Sidebar(selection: $section)
                .navigationSplitViewColumnWidth(min: 150, ideal: 180, max: 260)
        } detail: {
            detail
        }
        .sheet(item: presentedPlan) { presented in
            PresentedPlanSheet(plan: presented.plan, eligibility: model.eligibility, activity: activity) {
                // Files moved, so the rows on screen are stale.
                model.refresh()
            }
            // A later plan must start with its own ticks and its own log, never an earlier sheet's.
            .id(presented.id)
        }
    }

    /// What the menu bar's commands act on. While a preview sheet is up, they must not act on the
    /// window behind it; otherwise each acts on the place on screen.
    private func publishingCommandTargets(_ view: some View) -> some View {
        view
            .focusedSceneValue(\.selectedFileURLs, actsOnWindow ? selectedURLs : nil)
            .focusedSceneValue(
                \.selectedDownloadAddresses,
                actsOnWindow && section == .downloads ? model.downloadAddresses(for: selection) : nil
            )
            .focusedSceneValue(\.fileListFilter, actsOnWindow && section == .downloads ? $model.filter : nil)
            .focusedSceneValue(\.placeSwitcher, actsOnWindow ? PlaceSwitcher(show: show) : nil)
            #if DEBUG
            .focusedSceneValue(\.duplicateSearch, duplicates)
            #endif
    }

    private func observingChanges(_ view: some View) -> some View {
        view
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
            .onChange(of: activity.openings) {
                // Another log: its runs and items are not the ones that were selected.
                activitySelection = []
            }
            .onChange(of: section) { _, section in
                guard placeToFocus == section else { return }
                placeToFocus = nil
                // On the next turn, once the place is usable again.
                Task { @MainActor in
                    focusedPlace = section
                }
            }
    }

    /// The chosen place, with what every place shares below it: the duplicate search's progress,
    /// the activity log's notices and the status line.
    private var detail: some View {
        VStack(spacing: 0) {
            // Both places stay alive, so each keeps its scroll position, column widths, selection
            // and open cleanups while the other is shown.
            ZStack {
                content
                    .placeShown(section == .downloads)
                ActivityView(
                    activity: activity,
                    model: activityList,
                    selection: $activitySelection,
                    isShown: section == .activity,
                    focus: $focusedPlace
                )
                .placeShown(section == .activity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            if let progress = duplicates.progress {
                Divider()
                DuplicateProgressView(progress: progress, cancel: duplicates.cancel)
            }
            ActivityLogNotices(activity: activity)
            Divider()
            StatusBar(model: model, activity: activity, showsFileCounts: section == .downloads)
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
                // Refreshes the place on screen.
                Button {
                    refresh()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .keyboardShortcut("r", modifiers: .command)
                .help(section == .downloads ? Text("Refresh the list (⌘R)") : Text("Read the activity log again (⌘R)"))
                .disabled(section == .downloads ? !model.canRefresh : activity.log == nil)
            }
        }
    }

    /// True while menu commands may act on the window: no preview sheet is up in front of it.
    private var actsOnWindow: Bool {
        duplicates.presentedPlan == nil
    }

    /// Shows `place` from the View menu and gives its list keyboard focus, so the arrow keys work at
    /// once. The sidebar changes `section` itself and keeps focus.
    private func show(_ place: SidebarSection) {
        if section == place {
            focusedPlace = place
        } else {
            placeToFocus = place
            section = place
        }
    }

    private func refresh() {
        switch section {
        case .downloads:
            model.refresh()
        case .activity:
            activityList.reload(activity: activity)
        }
    }

    /// What File > Reveal in Finder acts on: the selected files, or the selected cleanup items whose
    /// files are still where the log says.
    private var selectedURLs: [URL] {
        switch section {
        case .downloads:
            Array(selection)
        case .activity:
            activityList.revealableURLs(for: activitySelection)
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
                FileTableView(model: model, selection: $selection, isShown: section == .downloads)
                    .focused($focusedPlace, equals: .downloads)
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

private extension View {
    /// The place on screen, or one kept alive out of sight: invisible, and taking no clicks, no
    /// keyboard focus and no VoiceOver attention.
    func placeShown(_ isShown: Bool) -> some View {
        opacity(isShown ? 1 : 0)
            .allowsHitTesting(isShown)
            .disabled(!isShown)
            .accessibilityHidden(!isShown)
    }
}
