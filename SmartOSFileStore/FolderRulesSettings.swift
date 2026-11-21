import FileStoreCore
import SwiftUI

/// Settings > Folders: for one managed folder, which cleanups it offers, which of them Tidy Now
/// runs, whether previews tick anything, and its own thresholds. A change is kept at once, and is
/// not a change on disk: it never goes in Activity.
struct FolderRulesSettings: View {
    @Environment(ActivityLogModel.self) private var activity

    @State private var selectedID: ManagedFolder.ID?

    /// The folders that were found, in the sidebar's order.
    private var folders: [ManagedFolder] {
        activity.folderEntries.compactMap(\.folder)
    }

    private var folder: ManagedFolder? {
        folders.first { $0.id == selectedID } ?? folders.first
    }

    var body: some View {
        Form {
            if let folder {
                Section {
                    Picker("Folder", selection: Binding(get: { folder.id }, set: { selectedID = $0 })) {
                        ForEach(folders) { folder in
                            Text(name(of: folder)).tag(folder.id)
                        }
                    }
                }
                actions(for: folder)
                ticks(for: folder)
                thresholds(for: folder)
                Section {
                    Button("Reset to Defaults") {
                        save(nil, for: folder)
                    }
                    .disabled(folder.rules == .defaults(for: folder.kind))
                    .help("Use the cleanups and thresholds this kind of folder starts with")
                }
            } else {
                Text("Folders appear here once the activity log is open.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .monospacedDigit()
        .fixedSize(horizontal: false, vertical: true)
    }

    private func name(of folder: ManagedFolder) -> String {
        folder.kind == .custom ? folder.displayName : folder.kind.standardName
    }

    @ViewBuilder
    private func actions(for folder: ManagedFolder) -> some View {
        Section {
            ForEach(CleanupAction.menuActions, id: \.self) { action in
                let rules = folder.rules
                LabeledContent(action.display.commandTitle) {
                    HStack(spacing: Design.Space.l) {
                        Toggle("Offered", isOn: binding(folder) { $0.offered.contains(action) } set: { rules, isOn in
                            if isOn { rules.offered.insert(action) } else { rules.offered.remove(action) }
                        })
                        Toggle("In Tidy now", isOn: binding(folder) { $0.inTidyNow.contains(action) } set: { rules, isOn in
                            if isOn { rules.inTidyNow.insert(action) } else { rules.inTidyNow.remove(action) }
                        })
                        .disabled(!rules.offered.contains(action))
                    }
                    .toggleStyle(.checkbox)
                }
                .help(action.display.explanation)
            }
        } header: {
            Text("Cleanups")
        } footer: {
            Text("A cleanup that is not offered is left out of this folder’s menus, Tidy now and the chat.")
                .foregroundStyle(.secondary)
        }
    }

    private func ticks(for folder: ManagedFolder) -> some View {
        Section {
            Toggle("Tick files in previews", isOn: binding(folder) { $0.ticksByDefault } set: { $0.ticksByDefault = $1 })
        } footer: {
            Text("When this is off, a preview ticks nothing and you tick each file yourself.")
                .foregroundStyle(.secondary)
        }
    }

    private func thresholds(for folder: ManagedFolder) -> some View {
        Section {
            override("Unused after", folder, \.unusedAfterDays, choices: [30, 60, 90]) { Text("^[\($0) day](inflect: true)") }
            override("Old after", folder, \.oldAfterDays, choices: [90, 180, 365]) { Text("^[\($0) day](inflect: true)") }
            override("Large from", folder, \.largeFileMegabytes, choices: [500, 1_000, 5_000]) {
                Text(CleanupSettings(largeDownloadMegabytes: $0).largeDownloadThreshold.formattedFileSize)
            }
        } header: {
            Text("Thresholds")
        } footer: {
            Text("Same as General uses the value set in the General tab.")
                .foregroundStyle(.secondary)
        }
    }

    private func override(
        _ title: LocalizedStringKey,
        _ folder: ManagedFolder,
        _ keyPath: WritableKeyPath<FolderRules, Int?>,
        choices: [Int],
        label: @escaping (Int) -> Text
    ) -> some View {
        let current = folder.rules[keyPath: keyPath]
        let values = Set(choices + [current].compactMap(\.self)).sorted()
        return Picker(title, selection: binding(folder) { $0[keyPath: keyPath] } set: { $0[keyPath: keyPath] = $1 }) {
            Text("Same as General").tag(Int?.none)
            ForEach(values, id: \.self) { value in
                label(value).tag(Int?.some(value))
            }
        }
    }

    private func binding<Value>(
        _ folder: ManagedFolder,
        get: @escaping (FolderRules) -> Value,
        set: @escaping (inout FolderRules, Value) -> Void
    ) -> Binding<Value> {
        Binding(
            get: { get(folder.rules) },
            set: { value in
                var rules = folder.rules
                set(&rules, value)
                rules.inTidyNow.formIntersection(rules.offered)
                save(rules == .defaults(for: folder.kind) ? nil : rules, for: folder)
            }
        )
    }

    private func save(_ rules: FolderRules?, for folder: ManagedFolder) {
        let id = folder.id
        Task { await activity.setRules(rules, of: id) }
    }
}
