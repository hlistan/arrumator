import ArrumatorCore
import ArrumatorRuntime
import SwiftUI

/// The archive's labels as one vocabulary: those that look alike and wait for the user first, then the labels of each
/// kind kept consistent, then what the user decided. Opening a label lets the user merge it into another or remove it
/// everywhere; every decision is a rule each reading follows from then on (`LabelActions`).
struct LabelsPage: View {
    @Environment(AppModel.self) private var model
    @State private var usage: [LabelKind: [LabelUsage]] = [:]
    @State private var suggestions: [LabelSuggestion] = []
    @State private var rules: [LabelRule] = []
    @State private var openSuggestion: String?
    @State private var expanded: Set<LabelKind> = []

    /// The kinds kept one vocabulary; the others have one form each and nothing to merge.
    private var kinds: [LabelKind] {
        let configured = model.runtime?.config.labels.vocabulary.kinds ?? [:]
        return LabelKind.allCases.filter { configured[$0] != nil && usage[$0]?.isEmpty == false }
    }

    var body: some View {
        Page(.labels, notes: "Merge labels that mean the same, or remove one you never want. Arrumator does the same for "
            + "every document it reads from then on, and tells the model how you want labels written.") {
            if !suggestions.isEmpty {
                PageSection("Look Alike") {
                    ForEach(suggestions) { suggestion in
                        if openSuggestion == suggestion.id {
                            SuggestionCard(suggestion: suggestion) { openSuggestion = nil }
                        } else {
                            ListRow(symbol: "questionmark.circle", tint: Palette.attention,
                                    title: "“\(suggestion.value)” and “\(suggestion.into)”", detail: Wording.labelKind(suggestion.kind))
                                .onTapGesture { withAnimation(.snappy) { openSuggestion = suggestion.id } }
                        }
                    }
                }
            }
            if kinds.isEmpty && suggestions.isEmpty {
                EmptyState(symbol: "tag", text: "No document has labels yet.")
            }
            ForEach(kinds, id: \.self) { kind in
                section(kind)
            }
            if !rules.isEmpty {
                PageSection("What You Decided") {
                    ForEach(rules) { rule in RuleRow(rule: rule) }
                }
            }
        }
        .task(id: model.activity) { await load() }
    }

    private func section(_ kind: LabelKind) -> some View {
        let all = usage[kind] ?? []
        let pageSize = model.runtime?.config.interface.pageSize ?? all.count
        let shown = expanded.contains(kind) ? all : Array(all.prefix(pageSize))
        return PageSection(Wording.labelKinds(kind)) {
            ForEach(shown, id: \.label) { item in
                if model.openLabel == item.label {
                    LabelCard(label: item.label, others: all.map(\.label.value).filter { $0 != item.label.value })
                } else {
                    ListRow(symbol: "tag", tint: .secondary, title: Wording.label(item.label))
                        .onTapGesture { withAnimation(.snappy) { model.openLabel = item.label } }
                }
            }
            if shown.count < all.count {
                Button("Show More") { expanded.insert(kind) }.buttonStyle(.link).padding(.top, 4)
            }
        }
    }

    private func load() async {
        let loaded = await model.load("Load labels") { runtime in
            (try await runtime.services.labels.usage(), try await runtime.services.labels.suggestions(),
             try await runtime.services.labels.rules())
        }
        guard let (usage, suggestions, rules) = loaded else { return }
        self.usage = usage
        self.suggestions = suggestions
        self.rules = rules.reversed()
    }
}

/// Two alike labels opened in place: merge one into the other, or keep them apart.
private struct SuggestionCard: View {
    @Environment(AppModel.self) private var model
    let suggestion: LabelSuggestion
    let close: () -> Void

    var body: some View {
        let (a, b) = (DocumentLabel(kind: suggestion.kind, value: suggestion.value), DocumentLabel(kind: suggestion.kind, value: suggestion.into))
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("“\(suggestion.value)” and “\(suggestion.into)”").font(.title3.weight(.semibold))
                Spacer()
                Button(action: close) { Image(systemName: "xmark") }.buttonStyle(.borderless).foregroundStyle(.secondary).help("Close")
            }
            Text("Two \(Wording.labelKinds(suggestion.kind).lowercased()) written alike. Are they one?")
                .foregroundStyle(.secondary)
            HStack(spacing: 14) {
                Button("Show Documents") { model.browse(b) }
                Spacer()
                Button("Keep Apart") { run("Keep apart") { try await $0.labels.keepApart(a, from: b.value) } }
                    .help("They mean different things: never merge them, and never ask again")
                Button("Use “\(suggestion.value)”") { run("Merge labels") { try await $0.labels.merge(b, into: a.value) } }
                Button("Use “\(suggestion.into)”") { run("Merge labels") { try await $0.labels.merge(a, into: b.value) } }
                    .help("Every document with “\(suggestion.value)” gets “\(suggestion.into)” instead")
            }
            .buttonStyle(.borderless)
            .font(.callout)
        }
        .card()
    }

    private func run(_ what: String, _ action: @escaping @Sendable (ArrumatorRuntime) async throws -> Void) {
        Task { await model.perform(what) { try await action($0) } }
    }
}

/// A label opened in place: merge it into another of its kind, or remove it from every document for good.
struct LabelCard: View {
    @Environment(AppModel.self) private var model
    let label: DocumentLabel
    /// The other labels of its kind, the most used first, to merge into.
    let others: [String]
    @State private var into = ""
    @State private var confirmingRemoval = false

    /// The labels offered to merge into, the most alike first.
    private var candidates: [String] {
        let limit = model.runtime?.config.labels.vocabulary.suggestionLimit ?? others.count
        return Array(others.sorted { LabelSimilarity.similarity($0, label.value) > LabelSimilarity.similarity($1, label.value) }.prefix(limit))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(Wording.label(label)).font(.title3.weight(.semibold)).textSelection(.enabled)
                    Text(Wording.labelKind(label.kind)).font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button { close() } label: { Image(systemName: "xmark") }.buttonStyle(.borderless).foregroundStyle(.secondary).help("Close")
            }
            HStack(spacing: 6) {
                Text("Merge into").foregroundStyle(.secondary)
                TextField(Wording.labelPrompt(label.kind), text: $into)
                    .textFieldStyle(.roundedBorder).frame(width: Style.mergeFieldWidth)
                    .onSubmit { merge() }
                if !candidates.isEmpty {
                    Menu {
                        ForEach(candidates, id: \.self) { value in Button(value) { into = value } }
                    } label: {
                        Image(systemName: "chevron.down")
                    }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help("Choose a label in use")
                }
                Button("Merge") { merge() }.disabled(into.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .controlSize(.small)
            HStack(spacing: 14) {
                Button("Show Documents") { model.browse(label) }
                Spacer()
                Button("Remove Everywhere…") { confirmingRemoval = true }
                    .help("Take it off every document, and never give it again")
            }
            .buttonStyle(.borderless)
            .font(.callout)
        }
        .card()
        .onExitCommand { close() }
        .confirmationDialog("Remove “\(Wording.label(label))” from every document?", isPresented: $confirmingRemoval) {
            Button("Remove Everywhere", role: .destructive) {
                let label = label
                Task { await model.perform("Remove label") { try await $0.labels.ignore(label) } }
            }
        } message: {
            Text("Arrumator will not give this label again. You can forget this decision under What You Decided.")
        }
    }

    private func merge() {
        let (label, value) = (label, into.trimmingCharacters(in: .whitespaces))
        guard !value.isEmpty else { return }
        Task { await model.perform("Merge labels") { try await $0.labels.merge(label, into: value) } }
        into = ""
    }

    private func close() {
        withAnimation(.snappy) { if model.openLabel == label { model.openLabel = nil } }
    }
}

/// One decision about labels, with a way to forget it.
private struct RuleRow: View {
    @Environment(AppModel.self) private var model
    let rule: LabelRule

    var body: some View {
        HStack(spacing: 8) {
            ListRow(symbol: Wording.ruleSymbol(rule.action), tint: .secondary, title: Wording.rule(rule),
                    detail: Wording.labelKind(rule.kind))
            Button("Forget") {
                guard let id = rule.id else { return }
                Task { await model.perform("Forget rule") { try await $0.labels.forget(rule: id) } }
            }
            .buttonStyle(.borderless).font(.callout)
            .help("Read documents without this rule from now on; documents keep their labels")
        }
    }
}

extension View {
    /// Opened in place, as a document's card is.
    func card() -> some View {
        padding(Style.cardPadding)
            .background(Style.card, in: .rect(cornerRadius: Style.cardCornerRadius))
            .shadow(color: Style.cardShadow, radius: Style.cardShadowRadius, y: Style.cardShadowOffset)
            .padding(.vertical, 8)
    }
}
