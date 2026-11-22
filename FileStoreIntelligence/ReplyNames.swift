import Foundation
import UniformTypeIdentifiers

/// File names in a reply that no managed folder has. The model is told never to guess a name, and
/// sometimes does; a reply that names a file that does not exist is not shown (docs/decisions/0033).
public struct ReplyNames: Sendable {
    /// Every name the reply may rightly quote: the files', their download sites' and the folders',
    /// and whatever the user wrote ("Do I have invoice.pdf?" may be answered "No, invoice.pdf…").
    private let known: [String]

    public init(_ snapshot: FolderSnapshot, question: String = "") {
        let names = snapshot.files.flatMap { [$0.name, $0.sourceSite].compactMap(\.self) } + snapshot.folders.map(\.name) + [question]
        known = names.map { $0.lowercased() }
    }

    /// Words that read as a file name: something, a dot, and an extension the system knows.
    /// "e.g." and "1.5" are not; "report.pdf" and "2025.pdf" are. A path ends at its last slash,
    /// and Markdown's marks around a name are not part of it ("~/Downloads/_report.pdf_").
    public static func fileNames(in text: String) -> [String] {
        text.matches(of: /[^\s"'“”‘’`*()\[\]<>,;:!?\/]+\.([A-Za-z][A-Za-z0-9]{0,9})(?![A-Za-z0-9])/).compactMap { match in
            let type = UTType(filenameExtension: String(match.output.1))
            let name = String(match.output.0).trimmingCharacters(in: CharacterSet(charactersIn: "_~"))
            return type.map { !$0.isDynamic } == true && !name.isEmpty ? name : nil
        }
    }

    /// True when `name` is part of a known name. A part is fine: a name with spaces reads as
    /// several words, and a long one reaches the model cut short.
    public func isKnown(_ name: String) -> Bool {
        let name = name.lowercased()
        return known.contains { $0.contains(name) }
    }

    /// The file names in `text` that are no part of a known name.
    public func unknown(in text: String) -> [String] {
        Self.fileNames(in: text).filter { !isKnown($0) }
    }
}
