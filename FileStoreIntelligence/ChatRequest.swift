import Foundation
import FoundationModels

/// A message read into what the user asked for, by one guided generation (`ChatParser`). Code acts
/// on it; the model writes no date, no action identifier and no file name of its own
/// (docs/decisions/0035). The order of the fields is the order the model writes them in: the kind
/// comes first, so every later field is written knowing it.
@Generable
public struct ChatRequest: Sendable, Equatable {
    @Generable
    public enum Kind: Sendable, Equatable {
        case list, count, cleanup, duplicates, overview, cannotDo, chat
    }

    /// What the app cannot do, by kind, so code words the answer.
    @Generable
    public enum CannotDo: Sendable, Equatable {
        case move, deleteForever, emptyTrash, open, send, compress, convert, schedule, watch, organize, restore, other
    }

    public var kind: Kind
    /// Optional, so a question's example need not write an empty list the model then fills.
    public var cleanups: [CleanupIntent]?
    public var files: FileSlots?
    public var sort: String?
    public var limit: Int?
    public var folder: String?
    /// "Those", "them", "the big ones": the request is about the files of the last result.
    public var aboutLastResult: Bool?
    public var cannotDo: CannotDo?

    public init(
        kind: Kind, cleanups: [CleanupIntent]? = nil, files: FileSlots? = nil, sort: String? = nil, limit: Int? = nil,
        folder: String? = nil, aboutLastResult: Bool? = nil, cannotDo: CannotDo? = nil
    ) {
        self.kind = kind
        self.cleanups = cleanups
        self.files = files
        self.sort = sort
        self.limit = limit
        self.folder = folder
        self.aboutLastResult = aboutLastResult
        self.cannotDo = cannotDo
    }

    /// The cleanups as the app's action names, in `offered` order, each once. "everything" is every
    /// offered action; an intent whose action is not offered is dropped.
    public func actions(offered: [String]) -> [String] {
        let cleanups = cleanups ?? []
        if cleanups.contains(.everything) { return offered }
        let asked = Set(cleanups.compactMap(\.action))
        return offered.filter(asked.contains)
    }
}

/// Which files, as slots the model fills from the user's words. Every field is optional.
@Generable
public struct FileSlots: Sendable, Equatable {
    @Guide(description: "Kind of file.", .anyOf(FileTypeGroup.allCases.map(\.rawValue)))
    public var kind: String?
    public var nameContains: String?
    @Guide(description: "Download site.")
    public var site: String?
    public var minMB: Double?
    public var maxMB: Double?
    public var added: Age?
    public var opened: Age?
    public var neverOpened: Bool?
    @Guide(description: "A mark the app gave it.", .anyOf(FolderSnapshot.Mark.allCases.map(\.rawValue)))
    public var mark: String?

    public init(
        kind: String? = nil, nameContains: String? = nil, site: String? = nil, minMB: Double? = nil, maxMB: Double? = nil,
        added: Age? = nil, opened: Age? = nil, neverOpened: Bool? = nil, mark: String? = nil
    ) {
        self.kind = kind
        self.nameContains = nameContains
        self.site = site
        self.minMB = minMB
        self.maxMB = maxMB
        self.added = added
        self.opened = opened
        self.neverOpened = neverOpened
        self.mark = mark
    }
}

/// An age as the user said it, counted back from today by code. The model never writes a date:
/// it wrote them badly (docs/decisions/0033, miss 5).
@Generable
public struct Age: Sendable, Equatable {
    @Generable
    public enum Relation: Sendable, Equatable {
        case within, olderThan, between, inMonth, onDay
    }

    @Generable
    public enum Unit: Sendable, Equatable {
        case days, weeks, months, years
    }

    public var relation: Relation
    public var amount: Int?
    public var unit: Unit?
    /// The far end of `between`.
    public var amountTo: Int?
    @Guide(.range(1...12))
    public var month: Int?
    public var year: Int?

    public init(relation: Relation, amount: Int? = nil, unit: Unit? = nil, amountTo: Int? = nil, month: Int? = nil, year: Int? = nil) {
        self.relation = relation
        self.amount = amount
        self.unit = unit
        self.amountTo = amountTo
        self.month = month
        self.year = year
    }
}

/// A cleanup in the user's words. The table below is the one place an intent becomes an action of
/// the app's registry; `ChatEvalPromptTests` checks it covers every one.
@Generable
public enum CleanupIntent: String, Sendable, CaseIterable {
    case exactCopies, almostSame, failedDownloads, unpackedZips, usedInstallers, messyNames, oldFiles, largeFiles, emptyFolders, everything

    /// The registry's action. Nil for `everything`, which is every action the folder offers.
    public var action: String? {
        switch self {
        case .exactCopies: "findDuplicates"
        case .almostSame: "reviewNearDuplicates"
        case .failedDownloads: "clearFailedDownloads"
        case .unpackedZips: "removeUnpackedZips"
        case .usedInstallers: "removeUsedInstallers"
        case .messyNames: "fixMessyNames"
        case .oldFiles: "archiveOldDownloads"
        case .largeFiles: "reviewLargeDownloads"
        case .emptyFolders: "removeEmptyFolders"
        case .everything: nil
        }
    }

    /// What the model reads beside the intent, in the user's words.
    var guide: String {
        switch self {
        case .exactCopies: "duplicates, the same file twice"
        case .almostSame: "near-duplicates, nearly the same"
        case .failedDownloads: "downloads that never finished"
        case .unpackedZips: "archives already extracted"
        case .usedInstallers: "installers for apps already installed"
        case .messyNames: "names with (1), copy, junk"
        case .oldFiles: "old or unused files, to archive"
        case .largeFiles: "big files to review"
        case .emptyFolders: "folders with nothing in them"
        case .everything: "tidy everything"
        }
    }
}
