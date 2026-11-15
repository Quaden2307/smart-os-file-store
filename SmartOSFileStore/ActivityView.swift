import FileStoreCore
import SwiftUI

/// The main window's Activity place: every confirmed cleanup, newest first. A run opens to show its
/// items, each with what was to be done, the file's name, why, what happened and when. Reveal in
/// Finder works for an item whose file is still where the log says it went.
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

    var body: some View {
        content
            .onAppear {
                model.reload(activity: activity)
            }
            .onChange(of: isShown) { _, isShown in
                // Read again each time the place is shown, so the files' places are current.
                if isShown {
                    model.reload(activity: activity)
                }
            }
            .onChange(of: activity.revision) {
                // A run ended, or the log was opened or replaced.
                model.reload(activity: activity)
            }
    }

    @ViewBuilder
    private var content: some View {
        if let error = activity.failure {
            // The problem and its ways out are in the banner under the list, as in Downloads.
            ContentUnavailableView(
                ActivityLogFailure(error).title,
                systemImage: "exclamationmark.triangle",
                description: Text("See the message below for what to do.")
            )
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

    /// One flat list: each run's row, then its items while it is open. Not a `DisclosureGroup`: a
    /// List's outline loses track of a group whose rows change while it is open (the items arrive
    /// after a placeholder), and then never closes it again.
    private var runList: some View {
        List(selection: $selection) {
            ForEach(model.runs) { run in
                let isExpanded = model.isExpanded(run.id)
                ActivityRunRow(run: run, isExpanded: isExpanded) {
                    setExpanded(run.id, !isExpanded)
                }
                .tag(ActivityRowID.run(run.id))
                if isExpanded {
                    if let changes = model.changes[run.id] {
                        ForEach(changes) { change in
                            ActivityChangeRow(change: change, run: run)
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
        .contextMenu(forSelectionType: ActivityRowID.self) { rows in
            let urls = model.revealableURLs(for: rows)
            Button("Reveal in Finder") {
                RevealInFinder.reveal(urls)
            }
            .disabled(urls.isEmpty)
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
