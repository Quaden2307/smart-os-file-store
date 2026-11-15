import FileStoreCore
import SwiftUI

/// The Activity window: every confirmed cleanup, newest first. A run opens to show its items, each
/// with what was to be done, the file's name, why, what happened and when. Reveal in Finder works
/// for an item whose file is still where the log says it went.
struct ActivityWindow: View {
    static let id = "activity"

    @Environment(ActivityLogModel.self) private var activity
    @State private var model = ActivityListModel()
    @State private var selection: Set<ActivityRowID> = []

    var body: some View {
        content
            .frame(minWidth: 620, minHeight: 360)
            // File > Reveal in Finder acts on the selected items of this window while it is in front.
            .focusedSceneValue(\.selectedFileURLs, model.revealableURLs(for: selection))
            .onAppear {
                activity.open()
                model.reload(from: activity.log, activity: activity)
            }
            .onChange(of: activity.revision) {
                // A run ended, or the log was opened or replaced.
                model.reload(from: activity.log, activity: activity)
            }
    }

    @ViewBuilder
    private var content: some View {
        if let error = activity.failure {
            ActivityLogProblemView(activity: activity, failure: ActivityLogFailure(error))
        } else if activity.log == nil || !model.hasLoaded {
            ProgressView("Loading…")
                .controlSize(.large)
        } else if model.runs.isEmpty {
            ContentUnavailableView(
                "No Activity Yet",
                systemImage: "clock",
                description: Text("Each cleanup you confirm is listed here, with what happened to every file.")
            )
        } else {
            runList
        }
    }

    private var runList: some View {
        List(selection: $selection) {
            ForEach(model.runs) { run in
                DisclosureGroup(isExpanded: expandedBinding(run.id)) {
                    if let changes = model.changes[run.id] {
                        ForEach(changes) { change in
                            ActivityChangeRow(change: change, run: run)
                                .tag(ActivityRowID.change(change.id))
                        }
                    } else {
                        ProgressView()
                            .controlSize(.small)
                            .accessibilityLabel("Loading items")
                    }
                } label: {
                    ActivityRunRow(run: run)
                }
                .tag(ActivityRowID.run(run.id))
            }
        }
        .contextMenu(forSelectionType: ActivityRowID.self) { rows in
            let urls = model.revealableURLs(for: rows)
            Button("Reveal in Finder") {
                RevealInFinder.reveal(urls)
            }
            .disabled(urls.isEmpty)
        }
        // Right and Left open and close the selected run, as in any outline, from the keyboard alone.
        .onKeyPress(.rightArrow) {
            setSelectedRunsExpanded(true) ? .handled : .ignored
        }
        .onKeyPress(.leftArrow) {
            setSelectedRunsExpanded(false) ? .handled : .ignored
        }
        .accessibilityLabel("Cleanups")
    }

    private func expandedBinding(_ runID: ActivityRun.ID) -> Binding<Bool> {
        Binding(
            get: { model.isExpanded(runID) },
            set: { model.setExpanded(runID, $0, log: activity.log, activity: activity) }
        )
    }

    /// Opens or closes the runs the selection touches.
    /// - Returns: False when nothing changed, so the key goes on to the list.
    private func setSelectedRunsExpanded(_ isExpanded: Bool) -> Bool {
        let runIDs = Set(selection.compactMap { model.runID(of: $0) }).filter { model.isExpanded($0) != isExpanded }
        guard !runIDs.isEmpty else { return false }
        for runID in runIDs {
            model.setExpanded(runID, isExpanded, log: activity.log, activity: activity)
        }
        if !isExpanded {
            // The items are hidden now; the selection moves to their runs.
            selection = Set(runIDs.map { ActivityRowID.run($0) })
        }
        return true
    }
}
