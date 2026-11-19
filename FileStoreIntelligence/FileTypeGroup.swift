import UniformTypeIdentifiers

/// The broad kinds the chat can filter and total by.
public enum FileTypeGroup: String, Sendable, Hashable, CaseIterable {
    case documents, images, installers, archives, video, audio, other

    private static let installerTypes = [
        UTType.diskImage, UTType("com.apple.installer-package-archive"), UTType("com.apple.installer-meta-package"),
    ].compactMap(\.self)

    private static let documentTypes: [UTType] = [.pdf, .text, .compositeContent, .spreadsheet, .presentation, .epub]

    /// Installers come before archives because an installer package is also an archive. A folder,
    /// an app and anything with no known type are "other".
    public init(contentType: UTType?) {
        guard let type = contentType else {
            self = .other
            return
        }
        func isOne(of types: [UTType]) -> Bool {
            types.contains { type.conforms(to: $0) }
        }
        self = if isOne(of: Self.installerTypes) {
            .installers
        } else if type.conforms(to: .archive) {
            .archives
        } else if type.conforms(to: .image) {
            .images
        } else if type.conforms(to: .audio) {
            .audio
        } else if type.conforms(to: .audiovisualContent) {
            .video
        } else if isOne(of: Self.documentTypes) {
            .documents
        } else {
            .other
        }
    }
}
