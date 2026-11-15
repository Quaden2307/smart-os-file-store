import Foundation

/// What happened to one change undo was asked to reverse.
public enum UndoItemOutcome: Sendable, Hashable {
    /// The file is back at `to`, its original place.
    case undone(to: URL)

    /// The file was left where it is, and why: refused when the plan was made, or by a check right
    /// before the move.
    case notUndone(UndoRefusal)

    /// The move back was attempted and the system refused it.
    case failed(CleanupExecutionError)
}

/// One change of an undo, and what became of it.
public struct UndoItemResult: Sendable, Hashable, Identifiable {
    public var id: ActivityChange.ID { changeID }

    /// The logged change undo was asked to reverse.
    public let changeID: ActivityChange.ID

    /// How it would be reversed. Nil when this version does not know the change's operation.
    public let operation: UndoStep.Operation?

    /// Where the file was before the change, and goes back to.
    public let originalPath: String

    /// Where the change put the file, when the log knows.
    public let currentPath: String?

    public let sizeInBytes: Int64

    public let outcome: UndoItemOutcome

    public init(
        changeID: ActivityChange.ID,
        operation: UndoStep.Operation?,
        originalPath: String,
        currentPath: String?,
        sizeInBytes: Int64,
        outcome: UndoItemOutcome
    ) {
        self.changeID = changeID
        self.operation = operation
        self.originalPath = originalPath
        self.currentPath = currentPath
        self.sizeInBytes = sizeInBytes
        self.outcome = outcome
    }

    init(_ step: UndoStep, outcome: UndoItemOutcome) {
        self.init(
            changeID: step.changeID,
            operation: step.operation,
            originalPath: step.originalPath,
            currentPath: step.currentPath,
            sizeInBytes: step.evidence.sizeInBytes,
            outcome: outcome
        )
    }

    init(_ refused: UndoPlan.Refused) {
        let change = refused.change
        self.init(
            changeID: change.id,
            operation: change.operation.flatMap(UndoStep.Operation.init(reversing:)),
            originalPath: change.originalPath,
            currentPath: change.resultingPath,
            sizeInBytes: change.sizeInBytes,
            outcome: .notUndone(refused.refusal)
        )
    }

    /// The file's name before the change, which undo gives it back.
    public var originalName: String {
        UndoPaths.name(of: originalPath) ?? originalPath
    }

    public var isUndone: Bool {
        if case .undone = outcome {
            return true
        }
        return false
    }

    /// Bytes this item took back out of the Trash.
    public var bytesTakenFromTrash: Int64 {
        isUndone && operation == .putBackFromTrash ? sizeInBytes : 0
    }
}

/// What an undo did: one result per change of the plan, its steps in the order they were tried,
/// then the changes refused when it was planned.
public struct UndoResult: Sendable, Hashable {
    public let target: UndoTarget

    /// The action of the run that was undone, as stored.
    public let undoneActionCode: String

    /// The undo's own run in the activity log. Nil when it could not be opened there.
    public let runID: ActivityRun.ID?

    public let items: [UndoItemResult]

    /// True when undo was stopped before every step was reached. Changes already undone stay undone.
    public let wasCancelled: Bool

    /// Set when the activity log could not be written. Undo stopped there: the changes after it
    /// were left as they were.
    public let logFailure: CleanupLogFailure?

    public init(
        target: UndoTarget,
        undoneActionCode: String,
        runID: ActivityRun.ID?,
        items: [UndoItemResult],
        wasCancelled: Bool,
        logFailure: CleanupLogFailure?
    ) {
        self.target = target
        self.undoneActionCode = undoneActionCode
        self.runID = runID
        self.items = items
        self.wasCancelled = wasCancelled
        self.logFailure = logFailure
    }

    /// The result for a plan with nothing to undo, which was never carried out: every refused change.
    public init(nothingToUndo plan: UndoPlan) {
        self.init(
            target: plan.target,
            undoneActionCode: plan.undoneActionCode,
            runID: nil,
            items: plan.refused.map(UndoItemResult.init),
            wasCancelled: false,
            logFailure: nil
        )
    }

    public var undone: [UndoItemResult] {
        items.filter(\.isUndone)
    }

    /// Everything that stayed where it was, in result order.
    public var notUndone: [UndoItemResult] {
        items.filter { !$0.isUndone }
    }

    public var undoneAction: CleanupAction? { CleanupAction(logCode: undoneActionCode) }

    /// Bytes taken back out of the Trash.
    public var bytesTakenFromTrash: Int64 {
        items.reduce(0) { $0 + $1.bytesTakenFromTrash }
    }
}

/// How far an undo has got.
public struct UndoProgress: Sendable, Hashable {
    /// Steps dealt with so far, whether undone or not.
    public let itemsCompleted: Int
    public let itemsTotal: Int

    public init(itemsCompleted: Int, itemsTotal: Int) {
        self.itemsCompleted = itemsCompleted
        self.itemsTotal = itemsTotal
    }

    /// Progress by steps, from 0 to 1. An undo with nothing to do counts as complete.
    public var fractionCompleted: Double {
        guard itemsTotal > 0 else { return 1 }
        return min(1, max(0, Double(itemsCompleted) / Double(itemsTotal)))
    }
}

extension UndoStep.Operation {
    /// The operation that reverses a cleanup row's `operation`. Nil for one that is itself a reversal.
    public init?(reversing operation: ActivityChange.Operation) {
        switch operation {
        case .moveToTrash:
            self = .putBackFromTrash
        case .rename:
            self = .renameBack
        case .move:
            self = .moveBack
        case .putBackFromTrash:
            return nil
        }
    }

    /// How an undo row stores this operation.
    var loggedOperation: ActivityChange.Operation {
        switch self {
        case .putBackFromTrash:
            .putBackFromTrash
        case .renameBack:
            .rename
        case .moveBack:
            .move
        }
    }
}
