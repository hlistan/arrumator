import ArrumatorCore
import SwiftUI

/// The processing log, read the way you would use it: pick the funnel step you want to make faster or more reliable
/// and see only the lines that come from it. History says what happened to a document; this says how the machinery
/// behaved while doing it.
struct ProcessingLogView: View {
    @Environment(AppModel.self) private var model
    @State private var entries: [LogEntry] = []
    @State private var step: String = ProcessingLogView.allSteps
    @State private var level: LogLevel = .info
    @State private var filter = ""

    static let allSteps = "all"

    private var steps: [FunnelStepConfig] { model.runtime?.config.stats.funnel.steps ?? [] }

    private var categories: Set<LogCategory>? {
        guard step != Self.allSteps, let match = steps.first(where: { $0.id == step }) else { return nil }
        return Set(match.logCategories)
    }

    var body: some View {
        VStack(spacing: 0) {
            controls
            Divider()
            if !steps.isEmpty { summary }
            Table(visible) {
                TableColumn(Wording.logTime) { Text($0.ts.formatted(date: .omitted, time: .standard)).monospacedDigit() }
                    .width(Style.logTimeColumnWidth)
                TableColumn(Wording.logLevel) { entry in
                    Text(entry.level.rawValue)
                        .foregroundStyle(Self.colour(entry.level))
                }
                .width(Style.logLevelColumnWidth)
                TableColumn(Wording.logPart) { Text($0.cat.rawValue).foregroundStyle(.secondary) }.width(Style.logPartColumnWidth)
                TableColumn(Wording.logWhat) { entry in
                    Text(entry.msg).lineLimit(1).help(entry.msg)
                }
                // Paths end with what tells them apart, so a long detail is shortened in its middle; the whole of it
                // shows under the pointer, and copies from the line's menu.
                TableColumn(Wording.logDetailColumn) { entry in
                    let detail = Wording.logFields(entry.fields)
                    Text(detail)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(detail)
                        .contextMenu { Button(Wording.copyLogLine) { model.copy(Wording.logLine(entry)) } }
                }
            }
            .font(.callout.monospaced())
            .overlay {
                if visible.isEmpty {
                    ContentUnavailableView(Wording.nothingLogged, systemImage: "text.alignleft",
                                           description: Text(Wording.linesAppear))
                }
            }
        }
        .task {
            entries = Log.shared.recent()
            for await entry in Log.shared.stream() { entries.append(entry) }
        }
    }

    private var controls: some View {
        HStack(spacing: Style.logControlsSpacing) {
            Picker(Wording.step, selection: $step) {
                Text(Wording.everyStep).tag(Self.allSteps)
                ForEach(steps) { Text($0.title).tag($0.id) }
            }
            .frame(width: Style.logStepPickerWidth)
            Picker(Wording.logDetailPicker, selection: $level) {
                ForEach(LogLevel.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .frame(width: Style.logLevelPickerWidth)
            TextField(Wording.filter, text: $filter).textFieldStyle(.roundedBorder).frame(minWidth: Style.logFilterMinWidth)
            Spacer()
            Button(Wording.openLogsFolder) { if let dir = model.runtime?.paths.logsDirectory { model.open(dir.path) } }
        }
        .padding(Style.logControlsSpacing)
    }

    /// Where the noise is: problems counted per funnel step, so the step worth working on is obvious.
    private var summary: some View {
        let counts = steps.map { definition -> (FunnelStepConfig, Int, Int) in
            let wanted = Set(definition.logCategories)
            let lines = entries.filter { wanted.contains($0.cat) }
            return (definition, lines.filter { $0.level == .error }.count, lines.filter { $0.level == .warning }.count)
        }
        return ScrollView(.horizontal) {
            HStack(spacing: Style.logSummarySpacing) {
                ForEach(counts, id: \.0.id) { definition, errors, warnings in
                    Button {
                        step = step == definition.id ? Self.allSteps : definition.id
                    } label: {
                        HStack(spacing: Style.logChipContentSpacing) {
                            Text(definition.title).lineLimit(1)
                            if errors > 0 { Text("\(errors)").foregroundStyle(Palette.problem).monospacedDigit() }
                            if warnings > 0 { Text("\(warnings)").foregroundStyle(Palette.attention).monospacedDigit() }
                            if errors == 0, warnings == 0 { Image(systemName: "checkmark").foregroundStyle(Palette.fine) }
                        }
                        .font(.caption)
                        .padding(Style.logChipInsets)
                        .background(step == definition.id ? AnyShapeStyle(.selection) : AnyShapeStyle(.quaternary),
                                    in: .capsule)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(Style.logSummaryInsets)
        }
        .scrollIndicators(.never)
    }

    private var visible: [LogEntry] {
        let categories = categories
        return entries.reversed().filter { entry in
            entry.level <= level
                && (categories.map { $0.contains(entry.cat) } ?? true)
                && (filter.isEmpty || entry.msg.localizedCaseInsensitiveContains(filter)
                    || entry.fields.values.contains { $0.localizedCaseInsensitiveContains(filter) })
        }
    }

    private static func colour(_ level: LogLevel) -> Color {
        switch level {
        case .error: Palette.problem
        case .warning: Palette.attention
        default: .secondary
        }
    }
}
