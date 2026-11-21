import FileStoreCore
import Foundation

extension FolderLocationError {
    /// Why a folder the user chose was not added, in one sentence.
    var addFolderSentence: String {
        switch self {
        case .refused(let refusal):
            refusal.sentence
        case .bookmarkUnusable:
            String(localized: "The app could not keep track of that folder. Try a folder on another disk.")
        case .standardFolderUnavailable(let kind):
            String(localized: "Your \(kind.standardName) folder could not be found.")
        case .overrideValueMissing, .overrideDoesNotExist, .overrideIsNotAFolder:
            String(localized: "The folders were chosen at launch and can’t be found.")
        }
    }
}

extension FolderSafetyRules.Refusal {
    /// Why a folder may not be managed, in one sentence.
    var sentence: String {
        switch self {
        case .notAFolder:
            String(localized: "That is not a folder, or it can’t be looked at.")
        case .volumeRoot:
            String(localized: "The top of a disk holds too much to clean up safely. Choose a folder on it instead.")
        case .homeFolder:
            String(localized: "Your home folder holds everything you have. Choose a folder inside it instead.")
        case .trash:
            String(localized: "The Trash is where cleaned-up files go, so it can’t be cleaned up itself.")
        case .insideLibrary:
            String(localized: "Folders in a Library belong to apps and to macOS, so they are left alone.")
        case .insideApplication:
            String(localized: "Folders inside an app belong to that app, so they are left alone.")
        case .appData:
            String(localized: "That folder holds Smart OS File Store’s own records.")
        case .systemLocation:
            String(localized: "macOS keeps that folder for itself, so it is left alone.")
        case .overlapsManagedFolder:
            String(localized: "That folder is already looked after, or holds or is inside a folder that is.")
        }
    }
}
