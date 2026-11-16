import Foundation

/// The words the activity log stores for the engine's typed values. They are written out here, one
/// by one, and never derived from a case's name, so renaming a case in code cannot change what an
/// existing log means. A code is never reused for another meaning. The app puts the values into the
/// user's language when it shows them; the log holds no sentences.
///
/// Every switch below is exhaustive, so a new case does not compile until it has a code.
struct ActivityLogCode: Hashable {
    let code: String
    /// The one value a case carries: a file name or the system's description.
    var detail: String?
}

extension CleanupAction {
    /// The definition's identifier, which is written out there for the same reason as every code here.
    var logCode: String {
        definition.identifier
    }

    init?(logCode: String) {
        guard let action = Self.allCases.first(where: { $0.definition.identifier == logCode }) else {
            return nil
        }
        self = action
    }
}

extension ActivityRun.State {
    var logCode: String {
        switch self {
        case .running:
            "running"
        case .finished:
            "finished"
        case .cancelled:
            "cancelled"
        case .interrupted:
            "interrupted"
        }
    }

    /// A state this version does not know is shown as interrupted: the run did not end in a way
    /// this version can vouch for.
    init(logCode: String) {
        switch logCode {
        case "running":
            self = .running
        case "finished":
            self = .finished
        case "cancelled":
            self = .cancelled
        default:
            self = .interrupted
        }
    }
}

extension ActivityChange.Operation {
    init(_ operation: ProposedChange.Operation) {
        switch operation {
        case .moveToTrash:
            self = .moveToTrash
        case .rename:
            self = .rename
        case .move:
            self = .move
        }
    }

    var logCode: String {
        switch self {
        case .moveToTrash:
            "trash"
        case .rename:
            "rename"
        case .move:
            "move"
        case .putBackFromTrash:
            "putBack"
        }
    }

    init?(logCode: String) {
        switch logCode {
        case "trash":
            self = .moveToTrash
        case "rename":
            self = .rename
        case "move":
            self = .move
        case "putBack":
            self = .putBackFromTrash
        default:
            return nil
        }
    }
}

extension ProposedChange.Reason {
    var logCode: ActivityLogCode {
        switch self {
        case .sameContent(let keptName):
            ActivityLogCode(code: "sameContent", detail: keptName)
        case .messyName(let fix):
            ActivityLogCode(code: "messyName", detail: fix.logDetail)
        case .oldDownload:
            ActivityLogCode(code: "oldDownload")
        case .failedDownload(_, let finishedFileName):
            // The date is the change's `dateModified`, already in the row, so it is not stored twice.
            ActivityLogCode(code: "failedDownload", detail: finishedFileName)
        case .unpackedZip(let unpackedTo):
            ActivityLogCode(code: "unpackedZip", detail: unpackedTo)
        case .usedInstaller(let evidence):
            ActivityLogCode(code: "usedInstaller", detail: evidence.logDetail)
        }
    }

    /// The reason a row's codes describe. `dateModified` is the row's own, which a failed
    /// download's date is; a failed download without one reads as unknown, as an unknown code does.
    init?(logCode: ActivityLogCode, dateModified: Date?) {
        switch logCode.code {
        case "sameContent":
            self = .sameContent(asFileNamed: logCode.detail ?? "")
        case "messyName":
            // A row without a detail, or with one this version cannot read, still says it was a messy name.
            self = .messyName(logCode.detail.flatMap(MessyNameFix.init(logDetail:)) ?? MessyNameFix(fixes: []))
        case "oldDownload":
            self = .oldDownload
        case "failedDownload":
            guard let dateModified else {
                return nil
            }
            self = .failedDownload(stoppedOn: dateModified, finishedFileName: logCode.detail)
        case "unpackedZip":
            // Every row this version writes names the copy; one without reads as unknown.
            guard let unpackedTo = logCode.detail else {
                return nil
            }
            self = .unpackedZip(unpackedTo: unpackedTo)
        case "usedInstaller":
            guard let evidence = logCode.detail.flatMap(UsedInstallerEvidence.init(logDetail:)) else {
                return nil
            }
            self = .usedInstaller(evidence)
        default:
            return nil
        }
    }
}

extension MessyNameFix {
    /// The detail a `messyName` reason stores: JSON with written-out keys, as for an installer.
    /// A fix of a kind this version does not know is left out when read.
    var logDetail: String {
        var object: [String: Any] = ["fixes": fixes.map(\.logObject)]
        object["taken"] = takenName
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else {
            return ""
        }
        return String(decoding: data, as: UTF8.self)
    }

    init?(logDetail: String) {
        guard let object = (try? JSONSerialization.jsonObject(with: Data(logDetail.utf8))) as? [String: Any],
              let fixes = object["fixes"] as? [[String: Any]] else {
            return nil
        }
        self.init(fixes: fixes.compactMap(NameFix.init(logObject:)), takenName: object["taken"] as? String)
    }
}

extension NameFix {
    fileprivate var logObject: [String: Any] {
        switch self {
        case .decodedPercentEncoding(let escapes):
            ["rule": "decoded", "escapes": escapes]
        case .removedWebLeftover(let text):
            ["rule": "webLeftover", "text": text]
        case .removedDoubledExtension(let text):
            ["rule": "doubledExtension", "text": text]
        case .removedCopySuffix(let text):
            ["rule": "copySuffix", "text": text]
        case .collapsedSpaces:
            ["rule": "collapsedSpaces"]
        case .trimmedEnds:
            ["rule": "trimmedEnds"]
        }
    }

    fileprivate init?(logObject: [String: Any]) {
        let text = logObject["text"] as? String
        switch (logObject["rule"] as? String, text) {
        case ("decoded", _):
            guard let escapes = logObject["escapes"] as? [String] else { return nil }
            self = .decodedPercentEncoding(escapes: escapes)
        case ("webLeftover", let text?):
            self = .removedWebLeftover(text)
        case ("doubledExtension", let text?):
            self = .removedDoubledExtension(text)
        case ("copySuffix", let text?):
            self = .removedCopySuffix(text)
        case ("collapsedSpaces", _):
            self = .collapsedSpaces
        case ("trimmedEnds", _):
            self = .trimmedEnds
        default:
            return nil
        }
    }
}

extension UsedInstallerEvidence {
    /// The detail a `usedInstaller` reason stores: JSON with written-out keys, which a later
    /// version reads the same way. An unknown shape reads as an unknown reason.
    var logDetail: String {
        var object: [String: Any] = [
            "strength": strength == .strong ? "strong" : "possible",
            "name": name,
            "receipts": receiptIdentifiers,
            "others": otherMatches,
        ]
        object["version"] = version
        object["app"] = installedAppPath
        object["bundle"] = bundleIdentifier
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else {
            return ""
        }
        return String(decoding: data, as: UTF8.self)
    }

    init?(logDetail: String) {
        guard let object = (try? JSONSerialization.jsonObject(with: Data(logDetail.utf8))) as? [String: Any],
              let strength = object["strength"] as? String, strength == "strong" || strength == "possible",
              let name = object["name"] as? String,
              let receipts = object["receipts"] as? [String],
              let others = object["others"] as? Int else {
            return nil
        }
        self.init(
            strength: strength == "strong" ? .strong : .possible,
            name: name,
            version: object["version"] as? String,
            installedAppPath: object["app"] as? String,
            bundleIdentifier: object["bundle"] as? String,
            receiptIdentifiers: receipts,
            otherMatches: others
        )
    }
}

extension CleanupSkipReason {
    var logCode: ActivityLogCode {
        switch self {
        case .changedSinceScan:
            ActivityLogCode(code: "changedSinceScan")
        case .notFound:
            ActivityLogCode(code: "notFound")
        case .accessDenied:
            ActivityLogCode(code: "accessDenied")
        case .notDownloaded:
            ActivityLogCode(code: "notDownloaded")
        case .notARegularFile:
            ActivityLogCode(code: "notARegularFile")
        case .unreadable(let reason):
            ActivityLogCode(code: "unreadable", detail: reason)
        case .zipUnlistable(let problem):
            ActivityLogCode(code: "zipUnlistable", detail: problem.logCode)
        case .installerUnreadable(let problem):
            ActivityLogCode(code: "installerUnreadable", detail: problem.rawValue)
        case .diskImageInUse:
            ActivityLogCode(code: "diskImageInUse")
        case .keptFile:
            ActivityLogCode(code: "keptFile")
        case .notInPlan:
            ActivityLogCode(code: "notInPlan")
        case .markedKept:
            ActivityLogCode(code: "markedKept")
        case .outsideFolder:
            ActivityLogCode(code: "outsideFolder")
        case .folderUnavailable:
            ActivityLogCode(code: "folderUnavailable")
        case .keptFileMissing(let name):
            ActivityLogCode(code: "keptFileMissing", detail: name)
        case .keptFileNotVerified(let name):
            ActivityLogCode(code: "keptFileNotVerified", detail: name)
        case .unpackedCopyMissing(let name):
            ActivityLogCode(code: "unpackedCopyMissing", detail: name)
        case .unpackedCopyNotVerified(let name):
            ActivityLogCode(code: "unpackedCopyNotVerified", detail: name)
        case .unpackedCopyRecentlyChanged(let name):
            ActivityLogCode(code: "unpackedCopyRecentlyChanged", detail: name)
        case .installedAppMissing(let name):
            ActivityLogCode(code: "installedAppMissing", detail: name)
        case .installedAppChanged(let name):
            ActivityLogCode(code: "installedAppChanged", detail: name)
        case .cancelled:
            ActivityLogCode(code: "cancelled")
        case .destinationExists(let name):
            ActivityLogCode(code: "destinationExists", detail: name)
        case .invalidName:
            ActivityLogCode(code: "invalidName")
        case .destinationOutsideFolder:
            ActivityLogCode(code: "destinationOutsideFolder")
        case .destinationNotAFolder:
            ActivityLogCode(code: "destinationNotAFolder")
        case .destinationHidden:
            ActivityLogCode(code: "destinationHidden")
        case .activityLogUnavailable:
            ActivityLogCode(code: "activityLogUnavailable")
        }
    }

    init?(logCode: ActivityLogCode) {
        let detail = logCode.detail ?? ""
        switch logCode.code {
        case "changedSinceScan":
            self = .changedSinceScan
        case "notFound":
            self = .notFound
        case "accessDenied":
            self = .accessDenied
        case "notDownloaded":
            self = .notDownloaded
        case "notARegularFile":
            self = .notARegularFile
        case "unreadable":
            self = .unreadable(reason: detail)
        case "zipUnlistable":
            guard let problem = ZipListing.Problem(logCode: detail) else {
                return nil
            }
            self = .zipUnlistable(problem)
        case "installerUnreadable":
            guard let problem = InstallerFacts.Problem(rawValue: detail) else {
                return nil
            }
            self = .installerUnreadable(problem)
        case "diskImageInUse":
            self = .diskImageInUse
        case "keptFile":
            self = .keptFile
        case "notInPlan":
            self = .notInPlan
        case "markedKept":
            self = .markedKept
        case "outsideFolder":
            self = .outsideFolder
        case "folderUnavailable":
            self = .folderUnavailable
        case "keptFileMissing":
            self = .keptFileMissing(name: detail)
        case "keptFileNotVerified":
            self = .keptFileNotVerified(name: detail)
        case "unpackedCopyMissing":
            self = .unpackedCopyMissing(name: detail)
        case "unpackedCopyNotVerified":
            self = .unpackedCopyNotVerified(name: detail)
        case "unpackedCopyRecentlyChanged":
            self = .unpackedCopyRecentlyChanged(name: detail)
        case "installedAppMissing":
            self = .installedAppMissing(name: detail)
        case "installedAppChanged":
            self = .installedAppChanged(name: detail)
        case "cancelled":
            self = .cancelled
        case "destinationExists":
            self = .destinationExists(name: detail)
        case "invalidName":
            self = .invalidName
        case "destinationOutsideFolder":
            self = .destinationOutsideFolder
        case "destinationNotAFolder":
            self = .destinationNotAFolder
        case "destinationHidden":
            self = .destinationHidden
        case "activityLogUnavailable":
            self = .activityLogUnavailable
        default:
            return nil
        }
    }
}

extension ZipListing.Problem {
    /// The detail a `zipUnlistable` skip stores.
    var logCode: String {
        switch self {
        case .damaged:
            "damaged"
        case .encryptedListing:
            "encryptedListing"
        case .tooManyEntries:
            "tooManyEntries"
        case .nameTooLong:
            "nameTooLong"
        case .unreadableNames:
            "unreadableNames"
        }
    }

    init?(logCode: String) {
        switch logCode {
        case "damaged":
            self = .damaged
        case "encryptedListing":
            self = .encryptedListing
        case "tooManyEntries":
            self = .tooManyEntries
        case "nameTooLong":
            self = .nameTooLong
        case "unreadableNames":
            self = .unreadableNames
        default:
            return nil
        }
    }
}

extension UndoRefusal {
    var logCode: ActivityLogCode {
        switch self {
        case .alreadyUndone:
            ActivityLogCode(code: "alreadyUndone")
        case .nothingChanged:
            ActivityLogCode(code: "nothingChanged")
        case .interrupted:
            ActivityLogCode(code: "interrupted")
        case .isAnUndo:
            ActivityLogCode(code: "isAnUndo")
        case .unknownToThisVersion:
            ActivityLogCode(code: "unknownToThisVersion")
        case .otherFolder:
            ActivityLogCode(code: "otherFolder")
        case .folderUnavailable:
            ActivityLogCode(code: "folderUnavailable")
        case .trashLocationUnknown:
            ActivityLogCode(code: "trashLocationUnknown")
        case .notWhereRecorded:
            ActivityLogCode(code: "notWhereRecorded")
        case .missing:
            ActivityLogCode(code: "missing")
        case .replaced:
            ActivityLogCode(code: "replaced")
        case .changed:
            ActivityLogCode(code: "changed")
        case .cannotBeChecked:
            ActivityLogCode(code: "cannotBeChecked")
        case .originalNameTaken(let name):
            ActivityLogCode(code: "originalNameTaken", detail: name)
        case .notDownloaded:
            ActivityLogCode(code: "notDownloaded")
        case .hidden:
            ActivityLogCode(code: "hidden")
        case .accessDenied:
            ActivityLogCode(code: "accessDenied")
        case .cancelled:
            ActivityLogCode(code: "cancelled")
        case .activityLogUnavailable:
            ActivityLogCode(code: "activityLogUnavailable")
        }
    }

    init?(logCode: ActivityLogCode) {
        switch logCode.code {
        case "alreadyUndone":
            self = .alreadyUndone
        case "nothingChanged":
            self = .nothingChanged
        case "interrupted":
            self = .interrupted
        case "isAnUndo":
            self = .isAnUndo
        case "unknownToThisVersion":
            self = .unknownToThisVersion
        case "otherFolder":
            self = .otherFolder
        case "folderUnavailable":
            self = .folderUnavailable
        case "trashLocationUnknown":
            self = .trashLocationUnknown
        case "notWhereRecorded":
            self = .notWhereRecorded
        case "missing":
            self = .missing
        case "replaced":
            self = .replaced
        case "changed":
            self = .changed
        case "cannotBeChecked":
            self = .cannotBeChecked
        case "originalNameTaken":
            self = .originalNameTaken(name: logCode.detail ?? "")
        case "notDownloaded":
            self = .notDownloaded
        case "hidden":
            self = .hidden
        case "accessDenied":
            self = .accessDenied
        case "cancelled":
            self = .cancelled
        case "activityLogUnavailable":
            self = .activityLogUnavailable
        default:
            return nil
        }
    }
}

/// A failure as the log stores it: a code, and for the system's own errors what identifies them.
struct ActivityLogErrorCode: Hashable {
    let code: String
    var domain: String?
    var number: Int?
    var text: String?
}

extension CleanupExecutionError {
    var logCode: ActivityLogErrorCode {
        switch self {
        case .fileIsLocked:
            ActivityLogErrorCode(code: "fileIsLocked")
        case .accessDenied:
            ActivityLogErrorCode(code: "accessDenied")
        case .volumeReadOnly:
            ActivityLogErrorCode(code: "volumeReadOnly")
        case .trashUnavailable:
            ActivityLogErrorCode(code: "trashUnavailable")
        case .renameUnsupported:
            ActivityLogErrorCode(code: "renameUnsupported")
        case .other(let domain, let code, let description):
            ActivityLogErrorCode(code: "other", domain: domain, number: code, text: description)
        }
    }

    init?(logCode: ActivityLogErrorCode) {
        switch logCode.code {
        case "fileIsLocked":
            self = .fileIsLocked
        case "accessDenied":
            self = .accessDenied
        case "volumeReadOnly":
            self = .volumeReadOnly
        case "trashUnavailable":
            self = .trashUnavailable
        case "renameUnsupported":
            self = .renameUnsupported
        case "other":
            self = .other(domain: logCode.domain ?? "", code: logCode.number ?? 0, description: logCode.text ?? "")
        default:
            return nil
        }
    }
}

/// An outcome as the log stores it, spread over the columns of a `changes` row.
struct ActivityLogOutcomeCode: Hashable {
    static let started = "started"

    /// `started`, `trashed`, `renamed`, `moved`, `skipped` or `failed`; for an undo row, `started`,
    /// `undone`, `notUndone` or `failed`.
    let outcome: String
    /// The skip reason's or the failure's code.
    var code: String?
    var detail: String?
    var errorDomain: String?
    var errorNumber: Int?
    var errorText: String?
    /// Where the file went, when the outcome says so.
    var resultingPath: String?
}

extension ActivityLogOutcomeCode {
    init(_ outcome: CleanupItemOutcome) {
        switch outcome {
        case .trashed(let trashURL):
            self.init(outcome: "trashed", resultingPath: trashURL?.storedPath)
        case .renamed(_, let newURL):
            self.init(outcome: "renamed", resultingPath: newURL.storedPath)
        case .moved(_, let newURL):
            self.init(outcome: "moved", resultingPath: newURL.storedPath)
        case .skipped(let reason):
            let reasonCode = reason.logCode
            self.init(outcome: "skipped", code: reasonCode.code, detail: reasonCode.detail)
        case .failed(let error):
            let errorCode = error.logCode
            self.init(
                outcome: "failed",
                code: errorCode.code,
                errorDomain: errorCode.domain,
                errorNumber: errorCode.number,
                errorText: errorCode.text
            )
        }
    }

    /// The columns for what undo did to one change. Where the file went back to is the undo row's
    /// own `resultingPath`, written with its intent, so it is not repeated here.
    init(_ outcome: UndoItemOutcome) {
        switch outcome {
        case .undone:
            self.init(outcome: "undone")
        case .notUndone(let refusal):
            let refusalCode = refusal.logCode
            self.init(outcome: "notUndone", code: refusalCode.code, detail: refusalCode.detail)
        case .failed(let error):
            self.init(CleanupItemOutcome.failed(error))
        }
    }

    /// The outcome these columns describe, or `.unrecognized` when a code is not one this version knows.
    var value: ActivityChange.Outcome {
        switch outcome {
        case Self.started:
            return .started
        case "trashed":
            return .trashed
        case "renamed":
            return .renamed
        case "moved":
            return .moved
        case "undone":
            return .undone
        case "notUndone":
            guard let code, let refusal = UndoRefusal(logCode: ActivityLogCode(code: code, detail: detail)) else {
                return .unrecognized(code: code ?? outcome)
            }
            return .notUndone(refusal)
        case "skipped":
            guard let code, let reason = CleanupSkipReason(logCode: ActivityLogCode(code: code, detail: detail)) else {
                return .unrecognized(code: code ?? outcome)
            }
            return .skipped(reason)
        case "failed":
            guard let code,
                  let error = CleanupExecutionError(
                      logCode: ActivityLogErrorCode(code: code, domain: errorDomain, number: errorNumber, text: errorText)
                  ) else {
                return .unrecognized(code: code ?? outcome)
            }
            return .failed(error)
        default:
            return .unrecognized(code: outcome)
        }
    }
}
