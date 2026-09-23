import ArrumatorCore
import ArrumatorRuntime
import SwiftUI

/// The two steps after the logic changes, and the plan they produce, all on the Logic page: try the logic on a few
/// documents, then reprocess everything. While a plan forms, each decision shows as it is made, newest first, and
/// planning can be stopped at any point; once it is ready, every document with what would happen to it, the ones that
/// can move ticked or tickable, then Apply or Discard. Nothing moves before Apply, and the page never switches away.
struct LogicPlan: View {
    @Environment(AppModel.self) private var model
    /// The version of the archive's logic, to tell whether it has been tried since it last changed.
    let logicVersion: String?
    @State private var run: RethinkRunRecord?
    @State private var items: [RethinkItemRecord] = []
    @State private var includeUserPlaced = false
    @State private var showStaying = false
    @State private var open: Int64?

    private var trialSize: Int { model.runtime?.config.rethink.trialSize ?? 0 }
    private var reloadKey: String {
        "\(model.rethink.status?.rawValue ?? "")|\(model.rethink.decided)|\(model.rethink.moves)|\(model.activity)"
    }

    var body: some View {
        PageSection("Try, Then Reprocess") {
            if let run, run.status.isActive {
                plan(run)
            } else {
                if let run { lastResult(run) }
                steps
            }
        }
        .task(id: reloadKey) { await load() }
    }

    // MARK: Before a plan

    /// Whether the logic has changed since it was last tried or reprocessed.
    private var untried: Bool { run.map { $0.logicVersion != logicVersion } ?? true }
    /// A trial of this very logic has finished, so reprocessing everything is the next step.
    private var trialDone: Bool { !untried && run?.scope == .trial }

    @ViewBuilder private var steps: some View {
        if untried {
            Notice(text: run == nil ? "This logic has not been tried yet. Start with a few documents."
                : "The logic changed since it was last tried. Try it again before reprocessing everything.")
                .padding(.vertical, 6)
        }
        step(1, "Try it on a few documents", emphasised: !trialDone,
             "See where the logic would put \(trialSize) documents from across the archive. "
                + "The plan appears here, and nothing moves unless you apply it.") {
            Button("Try on \(trialSize) Documents") { Task { await model.startRethink(.trial, includeUserPlaced: false) } }
                .prominent(!trialDone)
        }
        step(2, "Reprocess everything", emphasised: trialDone,
             "Decide again where every processed document belongs. You review the plan here before anything moves, "
                + "and folders left empty are removed when you apply it.") {
            Toggle("Also documents you placed or confirmed yourself", isOn: $includeUserPlaced)
            Button("Reprocess All Documents") {
                let include = includeUserPlaced
                Task { await model.startRethink(.all, includeUserPlaced: include) }
            }
            .prominent(trialDone)
        }
    }

    /// How the last plan ended, so the result stays in view after it is applied, discarded or settled.
    private func lastResult(_ run: RethinkRunRecord) -> some View {
        ListRow(symbol: run.status == .applied ? "checkmark.circle.fill" : "circle", tint: Destination.logic.tint,
                title: run.summary ?? run.status.rawValue, detail: Format.date(run.finishedAt ?? run.startedAt), wraps: true)
            .padding(.vertical, 4)
    }

    private func step<Actions: View>(_ number: Int, _ title: String, emphasised: Bool, _ detail: String,
                                     @ViewBuilder actions: () -> Actions) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text("\(number)").font(.headline).foregroundStyle(emphasised ? Destination.logic.tint : .secondary).frame(width: 18)
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.headline).foregroundStyle(emphasised ? .primary : .secondary)
                Text(detail).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                actions()
            }
        }
        .padding(.vertical, 8)
    }

    // MARK: A plan under way

    @ViewBuilder private func plan(_ run: RethinkRunRecord) -> some View {
        let documents = Format.count(items.count, "document")
        let decided = items.count - items.filter { $0.status == .notDecided }.count
        let reach = decided == items.count ? documents : "\(decided) of \(documents)"
        let title = switch (run.scope, run.status) {
        case (.trial, .planning): "Trying the logic on \(documents)"
        case (.all, .planning): "Reprocessing \(documents) with the logic"
        case (.trial, _): "Where the logic would put \(reach)"
        case (.all, _): "Where the logic would put \(decided == items.count ? "all " : "")\(reach)"
        }
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline).padding(.top, 8)
            switch run.status {
            case .planning: planning
            case .ready: ready(run)
            case .applying: HStack { ProgressView().controlSize(.small); Text("Moving documents…").foregroundStyle(.secondary) }
            case .applied, .discarded, .settled: EmptyView()
            }
        }
    }

    /// Planning under way: how far it has got, a way to stop at any point, and every decision so far, newest first,
    /// so it is clear early whether the logic does what was meant.
    private var planning: some View {
        // Documents are decided in plan order, so the newest decision is the last one decided.
        let decided = Array(items.filter { $0.status != .pending }.reversed())
        return VStack(alignment: .leading, spacing: 8) {
            ProgressView(value: Double(decided.count), total: Double(max(items.count, 1)))
            Text("Asking the logic where each document belongs: \(decided.count) of \(items.count). Each decision shows "
                + "below as it is made. Nothing moves until you apply the plan.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let waiting = model.rethink.waiting { Notice(text: waiting) }
            HStack(spacing: 14) {
                Button("Stop Here") { Task { await model.perform("Stop planning") { try await $0.rethink.stopPlanning() } } }
                    .buttonStyle(.bordered)
                Button("Discard") { Task { await model.perform("Discard rethink") { try await $0.rethink.discard() } } }
                    .buttonStyle(.link)
                Spacer()
            }
            Text("Stop Here keeps what has been decided as the plan, to apply or discard. Discard throws it away, and the "
                + "logic can be changed again.")
                .font(.caption).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
            if !decided.isEmpty {
                group("Decided So Far") {
                    ForEach(decided) { item in
                        DecisionRow(item: item, archive: model.settings?.archiveURL, expanded: open == item.id) {
                            withAnimation(.snappy) { open = open == item.id ? nil : item.id }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder private func ready(_ run: RethinkRunRecord) -> some View {
        let moves = items.filter { $0.status == .move }
        let suggestions = items.filter(\.isUserChoice)
        let staying = items.filter { $0.status == .unchanged }
        let undecided = items.filter { ($0.status == .unsure && !$0.canMove) || $0.status == .failed || $0.status == .skipped }
        let ticked = items.filter { $0.selected && $0.canMove }
        let folders = RethinkStore.folders(run.plannedFolders, neededBy: items)
        let leftOut = items.filter { $0.status == .notDecided }.count

        Text(moves.isEmpty
             ? "The logic keeps every document where it is, except any suggestion you tick below."
             : "Ticked documents move when you apply. Untick any you want to stay where they are.")
            .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        if leftOut > 0 {
            Text("Planning was stopped before \(Format.count(leftOut, "document")) \(leftOut == 1 ? "was" : "were") decided; "
                + "\(leftOut == 1 ? "it stays" : "they stay") where \(leftOut == 1 ? "it is" : "they are").")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        if !moves.isEmpty {
            group("Would Move") { ForEach(moves) { row($0) } }
        }
        if !suggestions.isEmpty {
            group("Unsure: Tick to Take the Suggestion") { ForEach(suggestions) { row($0) } }
        }
        if !folders.isEmpty {
            group("New Folders") {
                ForEach(folders, id: \.code) { folder in
                    let area = folder.newArea?.name ?? model.taxonomy?.folder(code: folder.areaCode)?.name ?? folder.areaCode
                    ListRow(symbol: "folder.badge.plus", tint: Destination.logic.tint, title: "\(area) › \(folder.name)",
                            detail: folder.description)
                }
            }
        }
        if !staying.isEmpty {
            group("Staying Where They Are") {
                Button(showStaying ? "Hide \(staying.count)" : "Show \(staying.count)") { withAnimation(.snappy) { showStaying.toggle() } }
                    .buttonStyle(.link).padding(.vertical, 4)
                if showStaying {
                    ForEach(staying) { item in
                        ListRow(symbol: "equal.circle", tint: .secondary, title: item.fileName,
                                detail: Wording.place(of: item.fromPath, in: model.settings?.archiveURL))
                    }
                }
            }
        }
        if !undecided.isEmpty {
            group("Staying: No Place Suggested") {
                ForEach(undecided) { item in
                    ListRow(symbol: item.status == .failed ? "exclamationmark.circle" : "questionmark.circle", tint: .secondary,
                            title: item.fileName, detail: item.error ?? item.decision.map { Wording.decider($0) })
                }
            }
        }
        HStack(spacing: 14) {
            if ticked.isEmpty {
                Text("Nothing ticked, so applying would move nothing.").foregroundStyle(.secondary)
            } else {
                Button("Apply to \(Format.count(ticked.count, "Document"))") {
                    Task { await model.perform("Apply rethink") { try await $0.rethink.apply() } }
                }
                .buttonStyle(.borderedProminent)
            }
            Button(ticked.isEmpty ? "Close Plan" : "Discard") {
                Task { await model.perform("Discard rethink") { try await $0.rethink.discard() } }
            }
            .buttonStyle(.link)
            Spacer()
        }
        .padding(.top, 6)
        Text("The logic cannot be changed while this plan is open.").font(.caption).foregroundStyle(.tertiary)
    }

    private func group<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary).padding(.top, 6).padding(.bottom, 2)
            content()
        }
    }

    /// A document the plan can move: the checkbox decides, and clicking the name shows why the logic chose the place.
    @ViewBuilder private func row(_ item: RethinkItemRecord) -> some View {
        PlanRow(item: item, archive: model.settings?.archiveURL, expanded: open == item.id) {
            withAnimation(.snappy) { open = open == item.id ? nil : item.id }
        }
    }

    private func load() async {
        let loaded = await model.load("Load plan") { runtime -> (RethinkRunRecord?, [RethinkItemRecord]) in
            let store = RethinkStore(database: runtime.database)
            let active = try await store.activeRun()
            let latest = active == nil ? try await store.latestRun() : nil
            guard let run = active ?? latest, let id = run.id else { return (nil, []) }
            return (run, try await store.items(runID: id))
        }
        run = loaded?.0
        items = loaded?.1 ?? []
    }
}

/// One document the plan can move: a checkbox, its name, and where it goes. Only the name toggles the explanation,
/// so a click on the checkbox always reaches the checkbox.
private struct PlanRow: View {
    @Environment(AppModel.self) private var model
    let item: RethinkItemRecord
    let archive: URL?
    let expanded: Bool
    let toggleExpanded: () -> Void
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 9) {
                Toggle("", isOn: Binding(get: { item.selected }, set: { selected in
                    guard let id = item.id else { return }
                    Task { await model.perform("Change plan") { try await $0.rethink.select(itemID: id, selected) } }
                }))
                .toggleStyle(.checkbox).labelsHidden()
                HStack(spacing: 9) {
                    Text(item.fileName).lineLimit(1).truncationMode(.middle)
                        .foregroundStyle(item.selected ? .primary : .secondary)
                    Spacer(minLength: 16)
                    Text("\(Wording.place(of: item.fromPath, in: archive)) → \(item.targetPath.map { Wording.place(of: $0, in: archive) } ?? "")")
                        .foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                }
                .contentShape(.rect)
                .onTapGesture(perform: toggleExpanded)
            }
            .padding(.horizontal, 8)
            .frame(minHeight: Style.rowHeight)
            .background(hovering ? Style.hover : .clear, in: .rect(cornerRadius: Style.rowCornerRadius))
            .onHover { hovering = $0 }
            if expanded, let decision = item.decision { Reasoning(decision: decision) }
        }
    }
}

/// One decision as planning makes it: what the logic would do with the document and, opened, why.
private struct DecisionRow: View {
    let item: RethinkItemRecord
    let archive: URL?
    let expanded: Bool
    let toggle: () -> Void
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 9) {
                Image(systemName: item.status.symbol).foregroundStyle(item.status.tint).frame(width: Style.decisionSymbolWidth)
                Text(item.fileName).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 16)
                Text(Wording.outcome(of: item, in: archive)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
            }
            .padding(.horizontal, 8)
            .frame(minHeight: Style.rowHeight)
            .background(hovering ? Style.hover : .clear, in: .rect(cornerRadius: Style.rowCornerRadius))
            .contentShape(.rect)
            .onHover { hovering = $0 }
            .onTapGesture(perform: toggle)
            if expanded, let decision = item.decision { Reasoning(decision: decision) }
        }
    }
}

/// Why the logic chose a place: who decided, and the model's own reasoning.
private struct Reasoning: View {
    let decision: FilingDecision

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(Wording.decider(decision))
            if !decision.rationale.isEmpty {
                Text(decision.rationale).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .font(.callout)
        .padding(.leading, Style.reasoningIndent).padding(.bottom, 8)
    }
}

private extension View {
    /// The step to take next gets the prominent button; the other stays available but quiet.
    @ViewBuilder func prominent(_ on: Bool) -> some View {
        if on { buttonStyle(.borderedProminent) } else { buttonStyle(.bordered) }
    }
}

extension RethinkItemRecord {
    var fileName: String { (fromPath as NSString).lastPathComponent }
}
