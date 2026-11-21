import FileStoreCore
import SwiftUI

/// The main window's Activity place: every confirmed cleanup, newest first. A run opens to show its
/// items, each with what was to be done, the file's name, why, what happened and when. Reveal in
/// Finder works for an item whose file is still where the log says it went. A run or an item can be
/// undone by its Undo button, the context menu, Edit > Undo Selected, or VoiceOver's Undo action.
///
/// The main window keeps this place alive while Downloads is shown, so what is open, selected and
/// scrolled to stays as it was.
struct ActivityView: View {
    let activity: ActivityLogModel
    let model: ActivityListModel
    @Binding var selection: Set<ActivityRowID>

    /// True while this place is the one on screen.
    let isShown: Bool

    /// The window's keyboard focus, which the View menu moves here when it switches to Activity.
    var focus: FocusState<SidebarSection?>.Binding

    /// False while the window is busy (a search, a preview or another undo): Undo then does nothing.
    let canUndo: Bool

    let undo: @MainActor (UndoTarget) -> Void

    /// Runs Tidy Now, from the empty state of a new install. Nil while it cannot start.
    var tidyNow: (@MainActor () -> Void)?

    /// The folder whose runs are listed, or nil for every folder.
    @State private var folderFilter: ManagedFolder.ID?

    /// What has been cleaned over time, read with the list.
    @State private var insights: CleanupInsights?

    /// The week whose runs are listed, from a click on its bar, or nil for every week.
    @State private var weekFilter: Date?

    var body: some View {
        content
            .onAppear {
                reload()
            }
            .onChange(of: isShown) { _, isShown in
                // Read again each time the place is shown, so the files' places are current.
                if isShown {
                    reload()
                }
            }
            .onChange(of: activity.revision) {
                // A run ended, an undo ended, or the log was opened or replaced.
                reload()
            }
    }

    private func reload() {
        model.reload(activity: activity)
        guard let log = activity.log else { return }
        Task {
            // A log that cannot be read shows its own notice below the list.
            if let days = try? await log.dailyCleanups() {
                insights = CleanupInsights(days: days, now: .now, calendar: .current)
            }
        }
    }

    /// True when a run started in the week a bar click chose, or no week was chosen.
    private func isInWeek(_ run: ActivityRun) -> Bool {
        guard let weekFilter, let week = Calendar.current.dateInterval(of: .weekOfYear, for: weekFilter) else { return true }
        return week.contains(run.startedAt)
    }

    @ViewBuilder
    private var content: some View {
        if let error = activity.failure {
            // The problem and its ways out are in the banner under the list, as in Downloads.
            StateView(
                title: Text(ActivityLogFailure(error).title),
                symbol: "exclamationmark.triangle",
                message: Text("See the message below for what to do.")
            )
        } else if activity.log == nil || !model.hasLoaded {
            StateView.loading
        } else if model.runs.isEmpty {
            StateView(
                title: Text("No activity yet"),
                symbol: "clock",
                message: Text("Each cleanup you confirm is listed here, with how much it moved to the Trash over time.")
            ) {
                if let tidyNow {
                    Button("Tidy now", action: tidyNow)
                        .keyboardShortcut(.defaultAction)
                        .help("Check the folder on screen with every cleanup at once")
                }
            }
        } else {
            runList
        }
    }

    /// One flat list: each run's row, then its items while it is open. Not a `DisclosureGroup`: a
    /// List's outline loses track of a group whose rows change while it is open (the items arrive
    /// after a placeholder), and then never closes it again.
    private var runList: some View {
        VStack(spacing: 0) {
            if let insights, !insights.isEmpty {
                InsightsHeader(insights: insights, folderName: folderName(id:), selectedWeek: $weekFilter)
                Divider()
            }
            folderFilterBar
            Divider()
            runs
        }
    }

    /// The folders that have runs, for the filter.
    private var runFolders: [(id: ManagedFolder.ID, name: String)] {
        var seen: Set<ManagedFolder.ID> = []
        var folders: [(id: ManagedFolder.ID, name: String)] = []
        for run in model.runs {
            guard let id = run.folderID, seen.insert(id).inserted else { continue }
            folders.append((id, folderName(of: run)))
        }
        return folders.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private var folderFilterBar: some View {
        HStack {
            Picker("Folder", selection: $folderFilter) {
                Text("All folders").tag(ManagedFolder.ID?.none)
                ForEach(runFolders, id: \.id) { folder in
                    Text(folder.name).tag(ManagedFolder.ID?.some(folder.id))
                }
            }
            .pickerStyle(.menu)
            .fixedSize()
            .help("Show the cleanups of one folder")
            Spacer()
        }
        .padding(.horizontal, Design.Space.l)
        .padding(.vertical, Design.Space.s)
    }

    /// A folder's name by its ID, for the insights.
    private func folderName(id: ManagedFolder.ID) -> String {
        if let entry = activity.folderEntries.first(where: { $0.id == id }) {
            return entry.kind == .custom ? (entry.folder?.displayName ?? entry.storedName ?? "") : entry.kind.standardName
        }
        return model.runs.first { $0.folderID == id }.map { URL(filePath: $0.folderPath).lastPathComponent } ?? String(localized: "Removed folder")
    }

    /// The name a run's folder goes by now, or the name it had when the run was made.
    private func folderName(of run: ActivityRun) -> String {
        if let id = run.folderID, let entry = activity.folderEntries.first(where: { $0.id == id }) {
            return entry.kind == .custom ? (entry.folder?.displayName ?? entry.storedName ?? "") : entry.kind.standardName
        }
        return URL(filePath: run.folderPath).lastPathComponent
    }

    private var runs: some View {
        List(selection: $selection) {
            ForEach(model.runs.filter { (folderFilter == nil || $0.folderID == folderFilter) && isInWeek($0) }) { run in
                let isExpanded = model.isExpanded(run.id)
                ActivityRunRow(
                    run: run,
                    folderName: folderName(of: run),
                    isExpanded: isExpanded,
                    undoAvailability: availability(model.undoAvailability(for: run)),
                    toggle: { setExpanded(run.id, !isExpanded) },
                    undo: { undo(.run(run.id)) }
                )
                .tag(ActivityRowID.run(run.id))
                if isExpanded {
                    if let changes = model.changes[run.id] {
                        ForEach(changes) { change in
                            ActivityChangeRow(
                                change: change,
                                run: run,
                                undoAvailability: availability(model.undoAvailability(for: change, in: run)),
                                undo: { undo(.change(change.id)) }
                            )
                            .padding(.leading, ActivityRunRow.itemIndent)
                            .tag(ActivityRowID.change(change.id))
                        }
                    } else {
                        ProgressView()
                            .controlSize(.small)
                            .padding(.leading, ActivityRunRow.itemIndent)
                            .accessibilityLabel("Loading items")
                    }
                }
            }
        }
        .motion(Design.Motion.standard, value: model.expanded)
        .contextMenu(forSelectionType: ActivityRowID.self) { rows in
            let urls = model.revealableURLs(for: rows)
            Button("Reveal in Finder") {
                RevealInFinder.reveal(urls)
            }
            .disabled(urls.isEmpty)
            let target = canUndo ? model.undoTarget(for: rows) : nil
            Button("Undo") {
                if let target {
                    undo(target)
                }
            }
            .disabled(target == nil)
        } primaryAction: { rows in
            // Double-click or Return on a cleanup opens or closes it.
            for case .run(let runID) in rows {
                setExpanded(runID, !model.isExpanded(runID))
            }
        }
        .focused(focus, equals: .activity)
        // Right and Left open and close the selected run, as in any outline, from the keyboard alone.
        .onKeyPress(.rightArrow) {
            setSelectedRunsExpanded(true) ? .handled : .ignored
        }
        .onKeyPress(.leftArrow) {
            setSelectedRunsExpanded(false) ? .handled : .ignored
        }
        .accessibilityLabel("Cleanups")
    }

    /// Opens or closes a run, by its arrow, a double-click or the keyboard. Selected items of a run that
    /// closes give way to the run itself, so no command acts on rows that are out of sight.
    private func setExpanded(_ runID: ActivityRun.ID, _ isExpanded: Bool) {
        if !isExpanded {
            let hidden = selection.filter { $0 != .run(runID) && model.runID(of: $0) == runID }
            if !hidden.isEmpty {
                selection.subtract(hidden)
                selection.insert(.run(runID))
            }
        }
        model.setExpanded(runID, isExpanded, activity: activity)
    }

    /// A row's Undo state, greyed out while the window is busy.
    private func availability(_ availability: UndoAvailability) -> UndoAvailability {
        canUndo || availability != .available ? availability : .checking
    }

    /// Opens or closes the runs the selection touches.
    /// - Returns: False when nothing changed, so the key goes on to the list.
    private func setSelectedRunsExpanded(_ isExpanded: Bool) -> Bool {
        let runIDs = Set(selection.compactMap { model.runID(of: $0) }).filter { model.isExpanded($0) != isExpanded }
        guard !runIDs.isEmpty else { return false }
        for runID in runIDs {
            setExpanded(runID, isExpanded)
        }
        return true
    }
}
