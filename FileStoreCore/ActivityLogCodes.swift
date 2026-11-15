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
    var logCode: String {
        switch self {
        case .findDuplicates:
            "findDuplicates"
        case .fixMessyNames:
            "fixMessyNames"
        case .archiveOldDownloads:
            "archiveOldDownloads"
        }
    }

    init?(logCode: String) {
        switch logCode {
        case "findDuplicates":
            self = .findDuplicates
        case "fixMessyNames":
            self = .fixMessyNames
        case "archiveOldDownloads":
            self = .archiveOldDownloads
        default:
            return nil
        }
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
        case .messyName:
            ActivityLogCode(code: "messyName")
        case .oldDownload:
            ActivityLogCode(code: "oldDownload")
        }
    }

    init?(logCode: ActivityLogCode) {
        switch logCode.code {
        case "sameContent":
            self = .sameContent(asFileNamed: logCode.detail ?? "")
        case "messyName":
            self = .messyName
        case "oldDownload":
            self = .oldDownload
        default:
            return nil
        }
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
        case .keptFile:
            ActivityLogCode(code: "keptFile")
        case .notInPlan:
            ActivityLogCode(code: "notInPlan")
        case .outsideFolder:
            ActivityLogCode(code: "outsideFolder")
        case .folderUnavailable:
            ActivityLogCode(code: "folderUnavailable")
        case .keptFileMissing(let name):
            ActivityLogCode(code: "keptFileMissing", detail: name)
        case .keptFileNotVerified(let name):
            ActivityLogCode(code: "keptFileNotVerified", detail: name)
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
        case "keptFile":
            self = .keptFile
        case "notInPlan":
            self = .notInPlan
        case "outsideFolder":
            self = .outsideFolder
        case "folderUnavailable":
            self = .folderUnavailable
        case "keptFileMissing":
            self = .keptFileMissing(name: detail)
        case "keptFileNotVerified":
            self = .keptFileNotVerified(name: detail)
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

    /// `started`, `trashed`, `renamed`, `moved`, `skipped` or `failed`.
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
            self.init(outcome: "trashed", resultingPath: trashURL?.path(percentEncoded: false))
        case .renamed(_, let newURL):
            self.init(outcome: "renamed", resultingPath: newURL.path(percentEncoded: false))
        case .moved(_, let newURL):
            self.init(outcome: "moved", resultingPath: newURL.path(percentEncoded: false))
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
