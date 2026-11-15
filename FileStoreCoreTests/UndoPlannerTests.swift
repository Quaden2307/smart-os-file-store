import FileStoreCore
import Foundation
import Testing

/// The undo planner's decisions, from log rows and observations alone: no disk. The order a run is
/// undone in, what a run leaves out, and every reason a change cannot be undone.
@Suite("Undo planner")
struct UndoPlannerTests {
    private static let folder = URL(filePath: "/Users/someone/Downloads", directoryHint: .isDirectory)
    private static let trashFolder = URL(filePath: "/Users/someone/.Trash", directoryHint: .isDirectory)
    private static let modified = Date(timeIntervalSince1970: 1_700_000_000)

    private let planner = UndoPlanner(trash: .fixed(Self.trashFolder))

    private static func run(id: Int64 = 1, actionCode: String = "findDuplicates", folderPath: String = folder.path(percentEncoded: false)) -> ActivityRun {
        ActivityRun(
            id: id,
            actionCode: actionCode,
            folderPath: folderPath,
            startedAt: modified,
            finishedAt: modified,
            state: .finished,
            confirmedCount: 3,
            doneCount: 3,
            skippedCount: 0,
            failedCount: 0,
            bytesMovedToTrash: 300
        )
    }

    /// A change of run 1 that moved `name` to the Trash, unless told otherwise.
    private static func change(
        id: Int64,
        sequence: Int = 0,
        name: String = "report.pdf",
        operation: ActivityChange.Operation? = .moveToTrash,
        outcome: ActivityChange.Outcome = .trashed,
        resultingPath: String?? = .none,
        dateModified: Date? = modified,
        undoneAt: Date? = nil,
        undoesChangeID: Int64? = nil
    ) -> ActivityChange {
        let defaultPath: String? = switch operation {
        case .rename:
            folder.appending(path: "renamed \(name)").path(percentEncoded: false)
        case .move:
            folder.appending(path: "Old downloads").appending(path: name).path(percentEncoded: false)
        case .moveToTrash, .putBackFromTrash, nil:
            trashFolder.appending(path: name).path(percentEncoded: false)
        }
        return ActivityChange(
            id: id,
            runID: 1,
            sequence: sequence,
            operation: operation,
            originalPath: folder.appending(path: name).path(percentEncoded: false),
            resultingPath: resultingPath ?? defaultPath,
            sizeInBytes: 100,
            dateModified: dateModified,
            contentHash: nil,
            reason: .sameContent(asFileNamed: "kept.pdf"),
            outcome: outcome,
            createdFolders: [],
            attemptedAt: modified,
            undoneAt: undoneAt,
            fileNumber: 42,
            undoesChangeID: undoesChangeID
        )
    }

    private static let matchingFile = UndoItemFacts(isRegularFile: true, sizeInBytes: 100, dateModified: modified, fileNumber: 42, isDataless: false)

    /// What `observe` would see for a change that can be undone, with one part replaced.
    private static func seen(
        current: UndoObservation.Place = .item(matchingFile),
        original: UndoObservation.Place = .nothing,
        folderIsReachable: Bool = true
    ) -> UndoObservation {
        UndoObservation(currentPlace: current, originalPlace: original, folderIsReachable: folderIsReachable)
    }

    private func refusal(
        _ change: ActivityChange,
        run: ActivityRun = run(),
        observation: UndoObservation? = seen()
    ) -> UndoRefusal? {
        planner.assess(change, in: run, observation: observation, folderURL: Self.folder).refusal
    }

    // MARK: - Runs

    @Test func aWholeRunIsUndoneInTheReverseOfTheOrderItWasMadeIn() {
        let changes = [
            Self.change(id: 10, sequence: 0, name: "a.pdf"),
            Self.change(id: 11, sequence: 1, name: "b.pdf"),
            Self.change(id: 12, sequence: 2, name: "c.pdf"),
        ]
        let observations = Dictionary(uniqueKeysWithValues: changes.map { ($0.id, Self.seen()) })

        let plan = planner.plan(target: .run(1), run: Self.run(), changes: changes, observations: observations, folderURL: Self.folder)

        #expect(plan.steps.map(\.originalName) == ["c.pdf", "b.pdf", "a.pdf"])
        #expect(plan.steps.allSatisfy { $0.operation == .putBackFromTrash })
        #expect(plan.refused.isEmpty)
        #expect(plan.undoneAction == .findDuplicates)
    }

    @Test func aWholeRunLeavesOutWhatThereIsNothingToSayAboutAndListsTheRest() {
        let changes = [
            Self.change(id: 10, sequence: 0, name: "done.pdf"),
            Self.change(id: 11, sequence: 1, name: "skipped.pdf", outcome: .skipped(.changedSinceScan)),
            Self.change(id: 12, sequence: 2, name: "failed.pdf", outcome: .failed(.fileIsLocked)),
            Self.change(id: 13, sequence: 3, name: "undone.pdf", undoneAt: Self.modified),
            Self.change(id: 14, sequence: 4, name: "interrupted.pdf", outcome: .started),
            Self.change(id: 15, sequence: 5, name: "gone.pdf"),
        ]
        var observations = Dictionary(uniqueKeysWithValues: changes.map { ($0.id, Self.seen()) })
        observations[15] = Self.seen(current: .nothing)

        let plan = planner.plan(target: .run(1), run: Self.run(), changes: changes, observations: observations, folderURL: Self.folder)

        #expect(plan.steps.map(\.changeID) == [10])
        #expect(plan.refused.map(\.change.id) == [15, 14])
        #expect(plan.refused.map(\.refusal) == [.missing, .interrupted])
    }

    @Test func oneChangeIsAlwaysReportedWhateverTheReason() {
        let skipped = Self.change(id: 11, outcome: .skipped(.changedSinceScan))
        let plan = planner.plan(target: .change(11), run: Self.run(), changes: [skipped], observations: [11: Self.seen()], folderURL: Self.folder)
        #expect(plan.steps.isEmpty)
        #expect(plan.refused.map(\.refusal) == [.nothingChanged])
        #expect(refusal(Self.change(id: 12, undoneAt: Self.modified)) == .alreadyUndone)
    }

    // MARK: - What the log alone decides

    @Test func anUndoCannotBeUndone() {
        let undoRun = Self.run(actionCode: ActivityRun.undoActionCode)
        #expect(refusal(Self.change(id: 1, operation: .putBackFromTrash, outcome: .undone), run: undoRun) == .isAnUndo)
        #expect(refusal(Self.change(id: 2, undoesChangeID: 1)) == .isAnUndo)
    }

    @Test func whatThisVersionDoesNotKnowIsNotUndone() {
        #expect(refusal(Self.change(id: 1, operation: nil)) == .unknownToThisVersion)
        #expect(refusal(Self.change(id: 2, outcome: .unrecognized(code: "vaporized"))) == .unknownToThisVersion)
        // An operation and an outcome that do not belong together.
        #expect(refusal(Self.change(id: 3, operation: .rename, outcome: .trashed)) == .unknownToThisVersion)
    }

    @Test func onlyTheFolderTheAppLooksAfterIsUndone() {
        #expect(refusal(Self.change(id: 1), run: Self.run(folderPath: "/Users/someone/Desktop")) == .otherFolder)
        // The same folder, spelled with a trailing slash, is the same folder.
        #expect(refusal(Self.change(id: 2), run: Self.run(folderPath: "/Users/someone/Downloads/")) == nil)
    }

    @Test func undoActsOnlyWhereTheLogSaysTheChangePutTheFile() {
        #expect(refusal(Self.change(id: 1, resultingPath: .some(nil))) == .trashLocationUnknown)
        #expect(refusal(Self.change(id: 2, resultingPath: "/Users/someone/Documents/report.pdf")) == .notWhereRecorded)
        #expect(refusal(Self.change(id: 3, resultingPath: "/Users/someone/.Trash/inner/report.pdf")) == .notWhereRecorded)
        #expect(refusal(Self.change(id: 4, operation: .rename, outcome: .renamed, resultingPath: "/Users/someone/Desktop/report.pdf")) == .notWhereRecorded)
        // A move puts a file in a folder inside the scanned folder, never beside it or above it.
        #expect(refusal(Self.change(id: 5, operation: .move, outcome: .moved, resultingPath: "/Users/someone/Downloads/report 2.pdf")) == .notWhereRecorded)
        #expect(refusal(Self.change(id: 6, operation: .move, outcome: .moved, resultingPath: "/Users/someone/Downloads/../report.pdf")) == .notWhereRecorded)
        #expect(refusal(Self.change(id: 7, operation: .move, outcome: .moved, resultingPath: "/Users/someone/Downloads/.hidden/report.pdf")) == .notWhereRecorded)
        #expect(refusal(Self.change(id: 8, operation: .move, outcome: .moved)) == nil)
        #expect(refusal(Self.change(id: 9, operation: .rename, outcome: .renamed)) == nil)
    }

    // MARK: - What was seen

    @Test func theFileMustBeTheOneTheChangeMoved() {
        let change = Self.change(id: 1)
        func facts(size: Int64 = 100, date: Date = Self.modified, fileNumber: UInt64 = 42, isRegularFile: Bool = true, isDataless: Bool = false) -> UndoObservation.Place {
            .item(UndoItemFacts(isRegularFile: isRegularFile, sizeInBytes: size, dateModified: date, fileNumber: fileNumber, isDataless: isDataless))
        }
        #expect(refusal(change, observation: Self.seen()) == nil)
        #expect(refusal(change, observation: Self.seen(current: .nothing)) == .missing)
        #expect(refusal(change, observation: Self.seen(current: facts(size: 101))) == .changed)
        #expect(refusal(change, observation: Self.seen(current: facts(date: Self.modified.addingTimeInterval(1)))) == .changed)
        // Within the executor's tolerance for two readings of one date.
        #expect(refusal(change, observation: Self.seen(current: facts(date: Self.modified.addingTimeInterval(0.0005)))) == nil)
        #expect(refusal(change, observation: Self.seen(current: facts(fileNumber: 43))) == .replaced)
        #expect(refusal(change, observation: Self.seen(current: facts(isRegularFile: false))) == .replaced)
        #expect(refusal(change, observation: Self.seen(current: facts(isDataless: true))) == .notDownloaded)
        #expect(refusal(change, observation: Self.seen(current: .unreadable)) == .accessDenied)
        #expect(refusal(Self.change(id: 2, dateModified: nil), observation: Self.seen()) == .cannotBeChecked)
    }

    @Test func theOriginalNameMustBeFreeAndTheFolderThere() {
        let change = Self.change(id: 1, name: "report.pdf")
        #expect(refusal(change, observation: Self.seen(original: .item(Self.matchingFile))) == .originalNameTaken(name: "report.pdf"))
        #expect(refusal(change, observation: Self.seen(original: .unreadable)) == .accessDenied)
        #expect(refusal(change, observation: Self.seen(folderIsReachable: false)) == .folderUnavailable)
        #expect(refusal(change, observation: nil) == .cannotBeChecked)
    }
}
