import Foundation

/// What the user asked to undo: one logged change, or every change of a run that can still be undone.
public enum UndoTarget: Sendable, Hashable {
    case change(ActivityChange.ID)
    case run(ActivityRun.ID)
}

/// One change undo would reverse, with what proves that the file it finds is the one the change moved.
public struct UndoStep: Sendable, Hashable, Identifiable {
    /// How the change is reversed.
    public enum Operation: Sendable, Hashable {
        /// From the Trash back to the scanned folder, under the original name.
        case putBackFromTrash
        /// Back to the original name, in the scanned folder.
        case renameBack
        /// From a folder inside the scanned folder back to it, under the original name.
        case moveBack
    }

    public var id: ActivityChange.ID { changeID }

    /// The logged change this step reverses.
    public let changeID: ActivityChange.ID

    /// The run the change belongs to.
    public let runID: ActivityRun.ID

    /// The change's place in its run.
    public let sequence: Int

    public let operation: Operation

    /// Where the change put the file, and where it should be now.
    public let currentPath: String

    /// Where the file was before the change: where undo puts it back.
    public let originalPath: String

    public let evidence: UndoEvidence

    public init(
        changeID: ActivityChange.ID,
        runID: ActivityRun.ID,
        sequence: Int,
        operation: Operation,
        currentPath: String,
        originalPath: String,
        evidence: UndoEvidence
    ) {
        self.changeID = changeID
        self.runID = runID
        self.sequence = sequence
        self.operation = operation
        self.currentPath = currentPath
        self.originalPath = originalPath
        self.evidence = evidence
    }

    /// The file's name before the change, which undo gives it back.
    public var originalName: String {
        UndoPaths.name(of: originalPath) ?? originalPath
    }

    /// Bytes this step takes back out of the Trash.
    public var bytesTakenFromTrash: Int64 {
        operation == .putBackFromTrash ? evidence.sizeInBytes : 0
    }
}

/// What undoing a target would do: a plain value, like a cleanup plan. Making one changes nothing.
public struct UndoPlan: Sendable, Hashable {
    /// A change that changed something but cannot be undone now, and why.
    public struct Refused: Sendable, Hashable, Identifiable {
        public var id: ActivityChange.ID { change.id }
        public let change: ActivityChange
        public let refusal: UndoRefusal

        public init(change: ActivityChange, refusal: UndoRefusal) {
            self.change = change
            self.refusal = refusal
        }
    }

    public let target: UndoTarget

    /// The managed folder the target's run was made in, which every file goes back into. Nil only
    /// when the log does not say; nothing can be undone then.
    public let folderID: ManagedFolder.ID?

    /// Where that folder is now, or when it could not be found, where the run saw it: every step
    /// is refused then.
    public let folderURL: URL

    /// The action of the run the target belongs to, as stored, so the undo can be named after it.
    public let undoneActionCode: String

    /// The changes to reverse, in the order to reverse them: for a whole run, the reverse of the
    /// order in which they were made.
    public let steps: [UndoStep]

    /// Changes of the target that cannot be undone now. For a whole run, only those that changed
    /// something and were not undone already; for one change, that change whatever the reason.
    public let refused: [Refused]

    public init(target: UndoTarget, folderID: ManagedFolder.ID?, folderURL: URL, undoneActionCode: String, steps: [UndoStep], refused: [Refused]) {
        self.target = target
        self.folderID = folderID
        self.folderURL = folderURL
        self.undoneActionCode = undoneActionCode
        self.steps = steps
        self.refused = refused
    }

    public var isEmpty: Bool { steps.isEmpty }

    /// The action of the run being undone, when this version knows it.
    public var undoneAction: CleanupAction? { CleanupAction(logCode: undoneActionCode) }
}
