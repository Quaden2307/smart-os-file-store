import Charts
import FileStoreCore
import SwiftUI

/// The top of the Activity place: what the app has moved to the Trash and tidied, all time and
/// this month, a bar chart of the last twelve weeks by cleanup (or the running total), and small
/// breakdowns by cleanup and by folder. Clicking a week's bar filters the list below to that week.
struct InsightsHeader: View {
    let insights: CleanupInsights
    /// A folder's name by its ID, for the breakdown.
    let folderName: (ManagedFolder.ID) -> String
    @Binding var selectedWeek: Date?

    @State private var isCumulative = false
    @State private var hoveredWeek: Date?

    private struct Bar: Identifiable {
        let week: Date
        let action: String
        let bytes: Int64
        var id: String { "\(week.timeIntervalSinceReferenceDate)-\(action)" }
    }

    /// The actions that appear, in the app's order, so each keeps its colour.
    private var actions: [CleanupAction] {
        CleanupAction.allCases.filter { action in insights.weeks.contains { $0.byAction[action] != nil } }
    }

    private var bars: [Bar] {
        if isCumulative {
            return insights.weeks.map { Bar(week: $0.start, action: String(localized: "All cleanups"), bytes: $0.cumulative.bytesMovedToTrash) }
        }
        return insights.weeks.flatMap { week in
            actions.compactMap { action in
                week.byAction[action].map { Bar(week: week.start, action: action.display.commandTitle, bytes: $0.bytesMovedToTrash) }
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Design.Space.m) {
            headlines
            HStack {
                Text("Moved to the Trash, by week")
                    .font(Design.Typography.sectionTitle)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                Picker("Show", selection: $isCumulative) {
                    Text("Each week").tag(false)
                    Text("Running total").tag(true)
                }
                .pickerStyle(.segmented)
                .fixedSize()
                .help("Show each week’s space, or the total so far")
            }
            chart
            weekLine
            breakdowns
        }
        .padding(Design.Space.l)
    }

    private var headlines: some View {
        HStack(alignment: .firstTextBaseline, spacing: Design.Space.xl) {
            headline(insights.allTime.bytesMovedToTrash.formattedFileSize, Text("moved to the Trash, all time"))
            headline("\(insights.allTime.filesTidied)", Text("files tidied, all time"))
            headline(insights.thisMonth.bytesMovedToTrash.formattedFileSize, Text("moved to the Trash this month"))
        }
    }

    private func headline(_ value: String, _ label: Text) -> some View {
        VStack(alignment: .leading, spacing: Design.Space.tight) {
            Text(value)
                .font(Design.Typography.windowTitle)
            label
                .font(Design.Typography.secondary)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    private var chart: some View {
        let domain = isCumulative ? [String(localized: "All cleanups")] : actions.map(\.display.commandTitle)
        return Chart(bars) { bar in
            BarMark(x: .value("Week", bar.week, unit: .weekOfYear), y: .value("Moved to the Trash", bar.bytes))
                .foregroundStyle(by: .value("Cleanup", bar.action))
                .opacity(selectedWeek == nil || selectedWeek == bar.week ? 1 : 0.4)
                .accessibilityLabel(Text("Week of \(bar.week.formatted(.dateTime.day().month(.abbreviated))), \(bar.action)"))
                .accessibilityValue(Text(bar.bytes.formattedFileSize))
        }
        .chartForegroundStyleScale(domain: domain, range: domain.indices.map(Design.Chart.colour))
        .chartYAxis {
            AxisMarks { value in
                AxisValueLabel {
                    if let bytes = value.as(Int64.self) {
                        Text(bytes.formattedFileSize)
                    }
                }
            }
        }
        .chartOverlay { proxy in
            GeometryReader { geometry in
                Rectangle().fill(.clear).contentShape(.rect)
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let point):
                            hoveredWeek = week(at: point, proxy: proxy, geometry: geometry)
                        case .ended:
                            hoveredWeek = nil
                        }
                    }
                    .onTapGesture { point in
                        let week = week(at: point, proxy: proxy, geometry: geometry)
                        selectedWeek = week == selectedWeek ? nil : week
                    }
            }
        }
        .frame(height: Design.Chart.insightsHeight)
        .accessibilityLabel(isCumulative ? "Running total moved to the Trash, by week" : "Space moved to the Trash each week, by cleanup")
    }

    /// The week under `point`, as one of the chart's weeks.
    private func week(at point: CGPoint, proxy: ChartProxy, geometry: GeometryProxy) -> Date? {
        guard let frame = proxy.plotFrame else { return nil }
        let x = point.x - geometry[frame].origin.x
        guard let date: Date = proxy.value(atX: x) else { return nil }
        return insights.weeks.last { $0.start <= date }?.start
    }

    /// The exact figures of the week under the pointer, or the one selected.
    @ViewBuilder
    private var weekLine: some View {
        if let start = hoveredWeek ?? selectedWeek, let week = insights.weeks.first(where: { $0.start == start }) {
            HStack(spacing: Design.Space.s) {
                Text("Week of \(start.formatted(.dateTime.day().month(.abbreviated).year())): \(week.total.bytesMovedToTrash.formattedFileSize) moved to the Trash, ^[\(week.total.filesTidied) file](inflect: true) tidied")
                if selectedWeek != nil {
                    Button("Show all weeks") {
                        selectedWeek = nil
                    }
                    .buttonStyle(.link)
                }
            }
            .font(Design.Typography.secondary)
            .foregroundStyle(.secondary)
        } else {
            Text("Click a week to show its cleanups below.")
                .font(Design.Typography.secondary)
                .foregroundStyle(.secondary)
        }
    }

    private var breakdowns: some View {
        HStack(alignment: .top, spacing: Design.Space.xl) {
            breakdown(
                Text("By cleanup"),
                rows: insights.byAction.sorted { $0.value.bytesMovedToTrash > $1.value.bytesMovedToTrash }.map { ($0.key.display.commandTitle, $0.value) }
            )
            breakdown(
                Text("By folder"),
                rows: insights.byFolder.sorted { $0.value.bytesMovedToTrash > $1.value.bytesMovedToTrash }.map { (folderName($0.key), $0.value) }
            )
        }
    }

    private func breakdown(_ title: Text, rows: [(String, CleanupInsights.Figures)]) -> some View {
        VStack(alignment: .leading, spacing: Design.Space.xs) {
            title
                .font(Design.Typography.sectionTitle)
                .accessibilityAddTraits(.isHeader)
            Grid(alignment: .leading, horizontalSpacing: Design.Space.l, verticalSpacing: Design.Space.tight) {
                ForEach(rows.prefix(6), id: \.0) { name, figures in
                    GridRow {
                        Text(name)
                        Text(figures.bytesMovedToTrash.formattedFileSize)
                            .gridColumnAlignment(.trailing)
                        Text("^[\(figures.filesTidied) file](inflect: true)")
                            .foregroundStyle(.secondary)
                            .gridColumnAlignment(.trailing)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            .font(Design.Typography.secondary)
        }
    }
}
