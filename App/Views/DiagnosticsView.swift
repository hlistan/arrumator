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
                TableColumn("Time") { Text($0.ts.formatted(date: .omitted, time: .standard)).monospacedDigit() }
                    .width(80)
                TableColumn("Level") { entry in
                    Text(entry.level.rawValue)
                        .foregroundStyle(Self.colour(entry.level))
                }
                .width(60)
                TableColumn("Part") { Text($0.cat.rawValue).foregroundStyle(.secondary) }.width(70)
                TableColumn("What happened") { entry in
                    Text(entry.msg).lineLimit(1)
                }
                TableColumn("Detail") { entry in
                    Text(entry.fields.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "  "))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .textSelection(.enabled)
                }
            }
            .font(.callout.monospaced())
            .overlay {
                if visible.isEmpty {
                    ContentUnavailableView("Nothing logged yet", systemImage: "text.alignleft",
                                           description: Text("Lines appear as files are processed."))
                }
            }
        }
        .task {
            entries = Log.shared.recent()
            for await entry in Log.shared.stream() { entries.append(entry) }
        }
    }

    private var controls: some View {
        HStack(spacing: 8) {
            Picker("Step", selection: $step) {
                Text("Every step").tag(Self.allSteps)
                ForEach(steps) { Text($0.title).tag($0.id) }
            }
            .frame(width: 280)
            Picker("Detail", selection: $level) {
                ForEach(LogLevel.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .frame(width: 150)
            TextField("Filter", text: $filter).textFieldStyle(.roundedBorder).frame(minWidth: 120)
            Spacer()
            Button("Open logs folder") { if let dir = model.runtime?.paths.logsDirectory { model.open(dir.path) } }
        }
        .padding(8)
    }

    /// Where the noise is: problems counted per funnel step, so the step worth working on is obvious.
    private var summary: some View {
        let counts = steps.map { definition -> (FunnelStepConfig, Int, Int) in
            let wanted = Set(definition.logCategories)
            let lines = entries.filter { wanted.contains($0.cat) }
            return (definition, lines.filter { $0.level == .error }.count, lines.filter { $0.level == .warning }.count)
        }
        return ScrollView(.horizontal) {
            HStack(spacing: 6) {
                ForEach(counts, id: \.0.id) { definition, errors, warnings in
                    Button {
                        step = step == definition.id ? Self.allSteps : definition.id
                    } label: {
                        HStack(spacing: 5) {
                            Text(definition.title).lineLimit(1)
                            if errors > 0 { Text("\(errors)").foregroundStyle(.red).monospacedDigit() }
                            if warnings > 0 { Text("\(warnings)").foregroundStyle(.orange).monospacedDigit() }
                            if errors == 0, warnings == 0 { Image(systemName: "checkmark").foregroundStyle(.green) }
                        }
                        .font(.caption)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(step == definition.id ? AnyShapeStyle(.selection) : AnyShapeStyle(.quaternary),
                                    in: .capsule)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
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
        case .error: .red
        case .warning: .orange
        default: .secondary
        }
    }
}
