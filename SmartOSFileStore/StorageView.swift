import Charts
import FileStoreCore
import FileStoreIntelligence
import SwiftUI

/// The Storage place: what is taking space in the managed folders and what each cleanup could get
/// back. It only reads; a "get back" row opens that cleanup's own preview, where the user confirms.
struct StorageView: View {
    let model: StorageModel

    /// Opens the counted plan of a cleanup as its normal preview.
    let review: @MainActor (CleanupPlan, FolderPlace) -> Void

    /// Shows a file in its folder.
    let showInList: @MainActor (URL) -> Void

    /// The folder shown, or nil for every folder.
    @State private var selected: FolderPlace?

    private var shown: [StorageModel.Folder] {
        model.folders.filter { selected == nil || $0.place == selected }
    }

    var body: some View {
        if model.folders.isEmpty {
            StateView.loading
        } else if let failure = shown.first?.failure, shown.count == 1 {
            VStack(spacing: 0) {
                header
                ScanErrorView(failure: failure, retry: nil)
            }
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: Design.Space.xl) {
                    header
                    StorageFolderBars(folders: shown.filter { $0.failure == nil })
                    ReclaimableList(model: model, folders: shown, review: review)
                    LargestFiles(folders: shown, showInList: showInList)
                }
                .padding(Design.Space.l)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Design.Space.xs) {
            Picker("Folder", selection: $selected) {
                Text("All folders").tag(FolderPlace?.none)
                ForEach(model.folders) { folder in
                    Text(folder.name).tag(FolderPlace?.some(folder.place))
                }
            }
            .pickerStyle(.menu)
            .fixedSize()
            .help("Show one folder, or all of them")
            Text("Sizes are the space on disk of the items at the top level of each folder. Files kept only in the cloud count as zero.")
                .font(Design.Typography.secondary)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// One stacked bar per folder, split by kind, with a legend that is also the table of exact sizes.
private struct StorageFolderBars: View {
    let folders: [StorageModel.Folder]

    private struct Segment: Identifiable {
        let folder: String
        let group: FileTypeGroup
        let total: StorageReport.Total
        var id: String { folder + group.rawValue }
    }

    private var segments: [Segment] {
        folders.flatMap { folder in
            FileTypeGroup.allCases.compactMap { group in
                folder.byType[group].map { Segment(folder: folder.name, group: group, total: $0) }
            }
        }
    }

    /// The groups present, in their fixed order, so a group keeps its colour on every chart.
    private var groups: [FileTypeGroup] {
        FileTypeGroup.allCases.filter { group in folders.contains { $0.byType[group] != nil } }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Design.Space.m) {
            Text("What is taking space")
                .font(Design.Typography.sectionTitle)
                .accessibilityAddTraits(.isHeader)
            Chart(segments) { segment in
                BarMark(x: .value("Size", segment.total.bytes), y: .value("Folder", segment.folder), height: .fixed(Design.Chart.folderBar))
                    .foregroundStyle(by: .value("Kind", segment.group.title))
                    .accessibilityLabel(Text("\(segment.folder), \(segment.group.title)"))
                    .accessibilityValue(Text("\(segment.total.bytes.formattedFileSize), ^[\(segment.total.count) item](inflect: true)"))
            }
            .chartForegroundStyleScale(domain: groups.map(\.title), range: groups.indices.map(Design.Chart.colour))
            .chartLegend(.hidden)
            .chartXAxis {
                AxisMarks { value in
                    AxisValueLabel {
                        if let bytes = value.as(Int64.self) {
                            Text(bytes.formattedFileSize)
                        }
                    }
                }
            }
            .frame(height: CGFloat(folders.count) * (Design.Chart.folderBar + Design.Space.m) + Design.Space.xl)
            .accessibilityLabel("Space by folder and kind")
            legend
        }
    }

    /// Each kind with its colour, total size and count across the folders shown.
    private var legend: some View {
        Grid(alignment: .leading, horizontalSpacing: Design.Space.l, verticalSpacing: Design.Space.tight) {
            ForEach(Array(groups.enumerated()), id: \.element) { index, group in
                let total = folders.reduce(StorageReport.Total()) { sum, folder in
                    let part = folder.byType[group] ?? StorageReport.Total()
                    return StorageReport.Total(count: sum.count + part.count, bytes: sum.bytes + part.bytes, cloudOnlyCount: sum.cloudOnlyCount + part.cloudOnlyCount)
                }
                GridRow {
                    RoundedRectangle(cornerRadius: Design.Radius.badge)
                        .fill(Design.Chart.colour(index))
                        .frame(width: Design.Space.l, height: Design.Chart.barHeight)
                        .accessibilityHidden(true)
                    Text(group.title)
                    Text(total.bytes.formattedFileSize)
                        .gridColumnAlignment(.trailing)
                    Text("^[\(total.count) item](inflect: true)")
                        .foregroundStyle(.secondary)
                        .gridColumnAlignment(.trailing)
                    if total.cloudOnlyCount > 0 {
                        Text("\(total.cloudOnlyCount) in the cloud only")
                            .foregroundStyle(.secondary)
                    }
                }
                .accessibilityElement(children: .combine)
            }
        }
        .font(Design.Typography.secondary)
        .fixedSize()
    }
}

/// One row per cleanup: its bar, the space it would move to the Trash and how many files, and a
/// button that opens that cleanup's own preview of exactly those files.
private struct ReclaimableList: View {
    let model: StorageModel
    let folders: [StorageModel.Folder]
    let review: @MainActor (CleanupPlan, FolderPlace) -> Void

    private struct Entry: Identifiable {
        let place: FolderPlace
        let folder: String
        let row: ReclaimableSpace.Row
        let plan: CleanupPlan
        var id: String { "\(place)-\(row.action.rawValue)" }
    }

    private var entries: [Entry] {
        folders.flatMap { folder -> [Entry] in
            guard let space = model.reclaimable[folder.place] else { return [] }
            return space.rows.compactMap { row in
                space.plans.first { $0.action == row.action }.map {
                    Entry(place: folder.place, folder: folder.name, row: row, plan: $0)
                }
            }
        }
        .sorted { $0.row.bytes > $1.row.bytes }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Design.Space.s) {
            Text("What you can get back")
                .font(Design.Typography.sectionTitle)
                .accessibilityAddTraits(.isHeader)
            Text("Moved to the Trash, and free once the Trash is emptied. Counted as each preview ticks it, each file once.")
                .font(Design.Typography.secondary)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if folders.contains(where: { model.planning.contains($0.place) }) {
                ProgressLine(fraction: nil, text: Text("Checking what each cleanup would find…"), label: Text("Checking cleanups"))
            }
            let entries = entries
            let largest = max(entries.first?.row.bytes ?? 1, 1)
            if entries.isEmpty, !folders.contains(where: { model.planning.contains($0.place) }) {
                Text("Nothing to get back right now.")
                    .foregroundStyle(.secondary)
            }
            ForEach(entries) { entry in
                HStack(spacing: Design.Space.m) {
                    VStack(alignment: .leading, spacing: Design.Space.tight) {
                        Text(entry.row.action.display.commandTitle)
                        if folders.count > 1 {
                            Text(entry.folder)
                                .font(Design.Typography.secondary)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: Design.Space.m)
                    SizeBar(fraction: Double(entry.row.bytes) / Double(largest), height: Design.Chart.barHeight)
                        .frame(width: Design.Chart.rowBarWidth)
                    Text(entry.row.bytes.formattedFileSize)
                        .frame(minWidth: Design.Size.sizeColumn, alignment: .trailing)
                    Text("^[\(entry.row.count) file](inflect: true)")
                        .foregroundStyle(.secondary)
                        .frame(minWidth: Design.Size.sizeColumn, alignment: .trailing)
                    Button("Review…") {
                        review(entry.plan, entry.place)
                    }
                    .help("Open this cleanup’s preview of these files. Nothing changes until you confirm.")
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(Text("\(entry.row.action.display.commandTitle), \(entry.folder)"))
                .accessibilityValue(Text("\(entry.row.bytes.formattedFileSize), ^[\(entry.row.count) file](inflect: true)"))
            }
        }
    }
}

/// The ten files taking the most space, largest first, each with a thin bar. Clicking one shows it
/// in its folder.
private struct LargestFiles: View {
    let folders: [StorageModel.Folder]
    let showInList: @MainActor (URL) -> Void

    private var files: [(record: FileRecord, folder: String)] {
        Array(
            folders.flatMap { folder in folder.largest.map { ($0, folder.name) } }
                .sorted { StorageReport.localBytes(of: $0.0) > StorageReport.localBytes(of: $1.0) }
                .prefix(10)
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Design.Space.s) {
            Text("Largest files")
                .font(Design.Typography.sectionTitle)
                .accessibilityAddTraits(.isHeader)
            let files = files
            let largest = max(files.first.map { StorageReport.localBytes(of: $0.record) } ?? 1, 1)
            ForEach(Array(files.enumerated()), id: \.element.record.id) { rank, entry in
                Button {
                    showInList(entry.record.id)
                } label: {
                    HStack(spacing: Design.Space.m) {
                        Text("\(rank + 1)")
                            .foregroundStyle(.secondary)
                            .frame(width: Design.Icon.column, alignment: .trailing)
                        FileIconView(record: entry.record)
                        VStack(alignment: .leading, spacing: Design.Space.tight) {
                            Text(entry.record.displayName)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            SizeBar(fraction: Double(StorageReport.localBytes(of: entry.record)) / Double(largest), height: Design.Chart.thinBar)
                        }
                        if folders.count > 1 {
                            Text(entry.folder)
                                .foregroundStyle(.secondary)
                        }
                        Text(StorageReport.localBytes(of: entry.record).formattedFileSize)
                            .frame(minWidth: Design.Size.sizeColumn, alignment: .trailing)
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .help("Show this file in its folder")
                .accessibilityElement(children: .combine)
            }
        }
    }
}

/// A bar for a share of the largest value, on a grey track.
private struct SizeBar: View {
    let fraction: Double
    let height: CGFloat

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Design.Chart.structure)
                Capsule().fill(Design.Chart.colour(0))
                    .frame(width: max(height, geometry.size.width * min(max(fraction, 0), 1)))
            }
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }
}
