import ArrumatorCore
import ArrumatorRuntime
import SwiftUI

/// The archive's labels as one vocabulary: those that look alike and wait for the user first, then the labels of each
/// kind kept consistent and the user's own tags, then what the user decided. Opening a label lets the user merge it into
/// another or remove it everywhere; every decision is a rule each reading follows from then on (`LabelActions`).
struct LabelsPage: View {
    @Environment(AppModel.self) private var model
    @State private var usage: [LabelKind: [LabelUsage]] = [:]
    @State private var suggestions: [LabelSuggestion] = []
    @State private var rules: [LabelRule] = []
    @State private var openSuggestion: String?
    @State private var expanded: Set<LabelKind> = []

    /// The kinds written freely (`LabelsConfig.isWrittenFreely`): those kept one vocabulary, and tags; the others have
    /// one form each and nothing to merge.
    private var kinds: [LabelKind] {
        guard let labels = model.runtime?.config.labels else { return [] }
        return LabelKind.allCases.filter { labels.isWrittenFreely($0) && usage[$0]?.isEmpty == false }
    }

    var body: some View {
        Page(.labels, notes: Wording.labelsNotes) {
            if !suggestions.isEmpty {
                PageSection(Wording.lookAlike) {
                    ForEach(suggestions) { suggestion in
                        if openSuggestion == suggestion.id {
                            SuggestionCard(suggestion: suggestion) { openSuggestion = nil }
                        } else {
                            ListRow(symbol: "questionmark.circle", tint: Palette.attention,
                                    title: Wording.alike(suggestion.value, suggestion.into), detail: Wording.labelKind(suggestion.kind))
                                .rowAction { withAnimation(.snappy) { openSuggestion = suggestion.id } }
                        }
                    }
                }
            }
            if kinds.isEmpty && suggestions.isEmpty {
                EmptyState(symbol: "tag", text: Wording.noLabelsYet)
            }
            ForEach(kinds, id: \.self) { kind in
                section(kind)
            }
            if !rules.isEmpty {
                PageSection(Wording.whatYouDecided) {
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
                if model.session.openLabel == item.label {
                    LabelCard(label: item.label, others: all.map(\.label.value).filter { $0 != item.label.value })
                } else {
                    // The most used first, each with how many documents have it, which is why it comes where it does.
                    ListRow(symbol: "tag", tint: .secondary, title: Wording.label(item.label),
                            detail: Format.count(item.documents, "document"))
                        .rowAction { withAnimation(.snappy) { model.session.openLabel = item.label } }
                }
            }
            if shown.count < all.count {
                Button(Wording.showMore) { expanded.insert(kind) }.buttonStyle(.link).padding(.top, Style.showMoreGap)
            }
        }
    }

    private func load() async {
        let loaded = await model.load(Wording.loadLabelsAction) { runtime in
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
        VStack(alignment: .leading, spacing: Style.labelCardSpacing) {
            HStack(alignment: .firstTextBaseline) {
                Text(Wording.alike(suggestion.value, suggestion.into)).font(.title3.weight(.semibold))
                Spacer()
                Button(action: close) { Image(systemName: "xmark") }.buttonStyle(.borderless).foregroundStyle(.secondary).help(Wording.close)
                    .accessibilityLabel(Wording.closeNamed(Wording.alike(suggestion.value, suggestion.into)))
            }
            Text(Wording.alikeBecause(suggestion.reason, kind: suggestion.kind))
                .foregroundStyle(.secondary)
            HStack(spacing: Style.actionSpacing) {
                Button(Wording.showDocuments) { model.browse(b) }
                Spacer()
                Button(Wording.keepApart) { run(Wording.keepApartAction) { try await $0.labels.keepApart(a, from: b.value) } }
                    .help(Wording.keepApartHelp)
                Button(Wording.use(suggestion.value)) { run(Wording.mergeLabelsAction) { try await $0.labels.merge(b, into: a.value) } }
                Button(Wording.use(suggestion.into)) { run(Wording.mergeLabelsAction) { try await $0.labels.merge(a, into: b.value) } }
                    .help(Wording.mergeHelp(suggestion.value, into: suggestion.into))
            }
            .buttonStyle(.borderless)
            .font(.callout)
        }
        .card()
    }

    private func run(_ what: String, _ action: @escaping @Sendable (ArrumatorRuntime) async throws -> Void) {
        Task<Void, Never> { await model.perform(what) { try await action($0) } }
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
    /// The labels offered to merge into, the most alike first (`LabelSimilarity.mostAlike`), worked out when the card
    /// opens or the labels change, never as it is drawn.
    @State private var candidates: [String] = []

    var body: some View {
        VStack(alignment: .leading, spacing: Style.labelCardSpacing) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: Style.labelCardTitleSpacing) {
                    Text(Wording.label(label)).font(.title3.weight(.semibold)).textSelection(.enabled)
                    Text(Wording.labelKind(label.kind)).font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button { close() } label: { Image(systemName: "xmark") }.buttonStyle(.borderless).foregroundStyle(.secondary).help(Wording.close)
                    .accessibilityLabel(Wording.closeNamed(Wording.label(label)))
            }
            HStack(spacing: Style.inlineControlSpacing) {
                Text(Wording.mergeInto).foregroundStyle(.secondary)
                TextField(Wording.labelPrompt(label.kind), text: $into)
                    .accessibilityLabel(Wording.labelPrompt(label.kind))
                    .textFieldStyle(.roundedBorder).frame(width: Style.mergeFieldWidth)
                    .onSubmit { merge() }
                if !candidates.isEmpty {
                    Menu {
                        ForEach(candidates, id: \.self) { value in Button(value) { into = value } }
                    } label: {
                        Image(systemName: "chevron.down")
                    }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help(Wording.chooseLabelInUse)
                    .accessibilityLabel(Wording.chooseLabelInUse)
                }
                Button(Wording.merge) { merge() }.disabled(into.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .controlSize(.small)
            HStack(spacing: Style.actionSpacing) {
                Button(Wording.showDocuments) { model.browse(label) }
                Spacer()
                Button(Wording.removeEverywhereEllipsis) { confirmingRemoval = true }
                    .help(Wording.removeEverywhereHelp)
            }
            .buttonStyle(.borderless)
            .font(.callout)
        }
        .card()
        .onExitCommand { close() }
        .task(id: [label.value] + others) {
            guard let limit = model.runtime?.config.labels.vocabulary.suggestionLimit else { return }
            candidates = LabelSimilarity.mostAlike(to: label.value, among: others, limit: limit)
        }
        .confirmationDialog(Wording.removeEverywhereQuestion(Wording.label(label)), isPresented: $confirmingRemoval) {
            Button(Wording.removeEverywhere, role: .destructive) {
                let label = label
                Task<Void, Never> { await model.perform(Wording.removeLabelAction) { try await $0.labels.ignore(label) } }
            }
        } message: {
            Text(Wording.removedForGoodFromLabels)
        }
    }

    private func merge() {
        let (label, value) = (label, into.trimmingCharacters(in: .whitespaces))
        guard !value.isEmpty else { return }
        Task<Void, Never> { await model.perform(Wording.mergeLabelsAction) { try await $0.labels.merge(label, into: value) } }
        into = ""
    }

    private func close() {
        withAnimation(.snappy) { if model.session.openLabel == label { model.session.openLabel = nil } }
    }
}

/// One decision about labels, with a way to forget it.
private struct RuleRow: View {
    @Environment(AppModel.self) private var model
    let rule: LabelRule

    var body: some View {
        HStack(spacing: Style.ruleForgetSpacing) {
            ListRow(symbol: Wording.ruleSymbol(rule.action), tint: .secondary, title: Wording.rule(rule),
                    detail: Wording.labelKind(rule.kind))
            Button(Wording.forget) {
                guard let id = rule.id else { return }
                Task<Void, Never> { await model.perform(Wording.forgetRuleAction) { try await $0.labels.forget(rule: id) } }
            }
            .buttonStyle(.borderless).font(.callout)
            .help(Wording.forgetHelp)
        }
    }
}

extension View {
    /// Opened in place, as a document's card is.
    func card() -> some View {
        padding(Style.cardPadding)
            .background(Style.card, in: .rect(cornerRadius: Style.cardCornerRadius))
            .shadow(color: Style.cardShadow, radius: Style.cardShadowRadius, y: Style.cardShadowOffset)
            .padding(.vertical, Style.cardOuterPadding)
    }
}
