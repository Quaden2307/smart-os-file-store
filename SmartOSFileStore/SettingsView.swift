import FileStoreCore
import FileStoreIntelligence
import SwiftUI

/// The Settings window (⌘,): when files count as unused and as old, which the marks and Archive Old
/// Downloads go by, how big a download must be for Review Large Downloads, whether the chat bar
/// may use Apple Intelligence, and where the activity log is kept. The thresholds are the `CleanupSettings`
/// keys in the user's defaults; the main window watches them and marks again at once.
struct SettingsView: View {
    @Environment(ActivityLogModel.self) private var activity

    @AppStorage(CleanupSettings.unusedAfterDaysKey) private var unusedAfterDays = CleanupSettings.defaultUnusedAfterDays
    @AppStorage(CleanupSettings.oldAfterDaysKey) private var oldAfterDays = CleanupSettings.defaultOldAfterDays
    @AppStorage(CleanupSettings.largeDownloadMegabytesKey) private var largeDownloadMegabytes = CleanupSettings.defaultLargeDownloadMegabytes
    @AppStorage(IntelligenceAvailability.enabledKey) private var usesAppleIntelligence = true

    /// The database and its journal files, in bytes. Nil until read, or when there is no file.
    @State private var logSize: Int64?

    /// What the app goes by: a stored value `CleanupSettings` refuses (below 1, set with
    /// `defaults write`) shows as the default it uses instead.
    private var effective: CleanupSettings {
        CleanupSettings(unusedAfterDays: unusedAfterDays, oldAfterDays: oldAfterDays, largeDownloadMegabytes: largeDownloadMegabytes)
    }

    var body: some View {
        Form {
            Section {
                Picker("Treat files as unused after", selection: Binding(get: { effective.unusedAfterDays }, set: { unusedAfterDays = $0 })) {
                    ForEach(Self.choices([30, 60, 90], current: effective.unusedAfterDays), id: \.self) { days in
                        Text("^[\(days) day](inflect: true)").tag(days)
                    }
                }
                Picker("Mark files as old after", selection: Binding(get: { effective.oldAfterDays }, set: { oldAfterDays = $0 })) {
                    ForEach(Self.choices([90, 180, 365], current: effective.oldAfterDays), id: \.self) { days in
                        Text("^[\(days) day](inflect: true)").tag(days)
                    }
                }
            } footer: {
                Text("A file not opened for this long is marked Unused, or Never opened if it was never opened. Archive Old Downloads moves those files into Old downloads.")
                    .foregroundStyle(.secondary)
            }

            Section {
                Picker("List downloads as large from", selection: Binding(get: { effective.largeDownloadMegabytes }, set: { largeDownloadMegabytes = $0 })) {
                    ForEach(Self.choices([500, 1_000, 5_000], current: effective.largeDownloadMegabytes), id: \.self) { megabytes in
                        Text(CleanupSettings(largeDownloadMegabytes: megabytes).largeDownloadThreshold.formattedFileSize).tag(megabytes)
                    }
                }
            } footer: {
                Text("Review Large Downloads lists the files and apps taking at least this much space on disk.")
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Use Apple Intelligence", isOn: $usesAppleIntelligence)
            } footer: {
                Text("The chat bar answers questions about your Downloads on this Mac. Nothing leaves it.")
                    .foregroundStyle(.secondary)
            }

            Section("Activity Log") {
                if let databaseURL = activity.location?.databaseURL {
                    LabeledContent("Stored in") {
                        Text((databaseURL.path(percentEncoded: false) as NSString).abbreviatingWithTildeInPath)
                            .textSelection(.enabled)
                            .truncationMode(.middle)
                            .lineLimit(1)
                    }
                    LabeledContent("Size", value: logSize.map(\.formattedFileSize) ?? String(localized: "Not created yet"))
                    Button("Reveal in Finder") {
                        RevealInFinder.reveal([databaseURL])
                    }
                    .disabled(logSize == nil)
                    .help("Show the activity log’s file in Finder")
                } else {
                    Text("The activity log is not stored on disk.")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
        .task {
            logSize = activity.location?.databaseURL.flatMap(Self.size(ofDatabaseAt:))
        }
    }

    /// The offered values, plus the current one when it was set another way (`defaults write`).
    private static func choices(_ offered: [Int], current: Int) -> [Int] {
        Set(offered + [current]).sorted()
    }

    /// The database plus its `-wal` and `-shm` files beside it, or nil when the database is not there.
    private static func size(ofDatabaseAt url: URL) -> Int64? {
        let manager = FileManager.default
        func size(_ path: String) -> Int64? {
            (try? manager.attributesOfItem(atPath: path)[.size] as? NSNumber)?.int64Value
        }
        let path = url.path(percentEncoded: false)
        guard let database = size(path) else { return nil }
        return database + (size(path + "-wal") ?? 0) + (size(path + "-shm") ?? 0)
    }
}
