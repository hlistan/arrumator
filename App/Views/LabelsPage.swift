import ArrumatorCore
import ArrumatorRuntime
import SwiftUI

/// The archive's labels as one vocabulary: what the user and the model decided first, then the labels of each kind kept
/// consistent and the user's own tags, under which a tag of the user's is added. Labels that look alike are judged by the
/// model, which merges them or keeps them apart on its own (`LabelJudge`). Opening a label lets the user rename it, merge
/// it into another, or take it off every document, once or for good; every decision but taking it off once is a rule
/// each reading follows from then on (`LabelActions`).
struct LabelsPage: View {
    @Environment(AppModel.self) private var model
    @State private var listing: [LabelKind: [LabelUsage]] = [:]
    @State private var rules: [LabelRule] = []
    @State private var expanded: Set<LabelKind> = []
    /// Whether every rule is listed, past `interface.pageSize`.
    @State private var rulesInFull = false

    /// The kinds written freely (`LabelsConfig.isWrittenFreely`): those kept one vocabulary, and tags, which are listed
    /// always, as a tag is added there; the others have one form each and nothing to rename or merge.
    private var kinds: [LabelKind] {
        guard let labels = model.runtime?.config.labels else { return [] }
        return LabelKind.allCases.filter { labels.isWrittenFreely($0) && (listing[$0]?.isEmpty == false || $0.isUsersOwn) }
    }

    /// The kinds the page leaves out, as Core decides it (`LabelsConfig.isWrittenFreely`), never a list written by hand.
    private var kindsNotListed: [String] {
        guard let labels = model.runtime?.config.labels else { return [] }
        return LabelKind.allCases.filter { !labels.isWrittenFreely($0) }.map(\.groupName)
    }

    var body: some View {
        ScrollViewReader { proxy in
            page
                // An open card is brought into sight, however far down it is: the kind it is in is listed in full first.
                .task(id: model.session.openLabel) {
                    guard let open = model.session.openLabel else { return }
                    if let all = listing[open.kind], let place = all.firstIndex(where: { $0.label == open }),
                       place >= (model.runtime?.config.interface.pageSize ?? all.count) {
                        expanded.insert(open.kind)
                    }
                    await Task.yield()
                    withAnimation(.snappy) { proxy.scrollTo(open, anchor: .top) }
                }
        }
    }

    private var page: some View {
        Page(.labels, notes: Wording.labelsNotes) {
            if !kindsNotListed.isEmpty {
                Text(Wording.kindsNotListed(kindsNotListed)).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if listing.values.allSatisfy(\.isEmpty) {
                EmptyState(symbol: "tag", text: Wording.noLabelsYet)
            }
            // Before the labels, however many there are, so a rule is forgotten without scrolling past them all.
            if !rules.isEmpty {
                PageSection(Wording.whatYouDecided) {
                    let pageSize = model.runtime?.config.interface.pageSize ?? rules.count
                    ForEach(rulesInFull ? rules : Array(rules.prefix(pageSize))) { rule in RuleRow(rule: rule) }
                    if rules.count > pageSize {
                        Button(rulesInFull ? Wording.showFewer : Wording.showMore) { rulesInFull.toggle() }
                            .buttonStyle(.link).padding(.top, Style.showMoreGap)
                    }
                }
            }
            ForEach(kinds, id: \.self) { kind in
                section(kind)
            }
        }
        .task(id: model.activity) { await load() }
    }

    private func section(_ kind: LabelKind) -> some View {
        let all = listing[kind] ?? []
        let pageSize = model.runtime?.config.interface.pageSize ?? all.count
        let shown = expanded.contains(kind) ? all : Array(all.prefix(pageSize))
        // Built at once while it holds the open card, of any height (`PageSection`).
        return PageSection(Wording.labelKinds(kind), lazily: !shown.contains { $0.label == model.session.openLabel }) {
            if kind.isUsersOwn {
                AddTagRow(tags: all.map(\.label.value))
            }
            ForEach(shown, id: \.label) { item in
                if model.session.openLabel == item.label {
                    LabelCard(label: item.label, documents: item.documents, others: all.map(\.label.value).filter { $0 != item.label.value })
                        .id(item.label)
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
            (try await runtime.services.labels.listing(), try await runtime.services.labels.rules())
        }
        guard let (listing, rules) = loaded else { return }
        self.listing = listing
        self.rules = rules.reversed()
    }
}

/// A tag of the user's own added before any document has it, to give documents on their cards: refused as it is typed
/// when it is a tag already or no tag, by the rule adding applies (`LabelError.refusal(ofAdding:among:)`).
private struct AddTagRow: View {
    @Environment(AppModel.self) private var model
    /// The archive's tags, in use or added.
    let tags: [String]
    @State private var value = ""
    @State private var refusal: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Style.fieldRefusalSpacing) {
            HStack(spacing: Style.inlineControlSpacing) {
                // Named for what it is, whatever example it shows.
                TextField(Wording.newTagField, text: $value, prompt: Text(Wording.labelPrompt(.tag)))
                    .accessibilityLabel(Wording.newTagField)
                    .textFieldStyle(.roundedBorder).frame(width: Style.mergeFieldWidth)
                    .onSubmit { add() }
                Button(Wording.addTag) { add() }.disabled(typed == nil || refusal != nil)
            }
            .controlSize(.small)
            if let refusal {
                Text(refusal).font(.caption).foregroundStyle(Palette.attention).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, Style.addTagRowPadding)
        .onChange(of: [value] + tags, initial: true) {
            refusal = typed.flatMap { LabelError.refusal(ofAdding: $0, among: tags) }?.localizedDescription
        }
    }

    /// The tag typed; nil while the field is blank.
    private var typed: DocumentLabel? {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : DocumentLabel(kind: .tag, value: trimmed)
    }

    /// Adds the tag typed. One that cannot be added stays in the field, under why, to be corrected.
    private func add() {
        guard let typed, LabelError.refusal(ofAdding: typed, among: tags) == nil else { return }
        Task<Void, Never> { await model.perform(Wording.addTagAction) { try await $0.labels.add(typed) } }
        value = ""
    }
}

/// A label opened in place: rename it, merge it into another of its kind, or take it off every document, once or for good.
struct LabelCard: View {
    @Environment(AppModel.self) private var model
    let label: DocumentLabel
    /// How many documents have it; none for a tag added that no document has yet.
    let documents: Int
    /// The other labels of its kind, the most used first, to merge into.
    let others: [String]
    @State private var into = ""
    @State private var renamed = ""
    /// Why the label written to merge into, or the new name, cannot be, as Core says it (`LabelError.refusal(ofMerging:into:)`).
    @State private var refusal: String?
    @State private var renameRefusal: String?
    @State private var confirmingRemoval = false
    @State private var confirmingRemovalForGood = false
    /// What a merge, or a rename into a label in use, would change, while the user is asked whether to make it
    /// (`LabelActions.preview(merging:into:)`).
    @State private var asking: MergeQuestion?
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
                Button { close() } label: { Image(systemName: "xmark").frame(minWidth: Style.minimumHit.width, minHeight: Style.minimumHit.height) }
                    .buttonStyle(.borderless).foregroundStyle(.secondary).help(Wording.close).contentShape(.rect)
                    .accessibilityLabel(Wording.closeNamed(Wording.label(label)))
            }
            renaming
            merging
            HStack(spacing: Style.actionSpacing) {
                if documents > 0 {
                    Button(Wording.showDocuments) { model.browse(label) }
                }
                Spacer()
                Button(Wording.removeFromEveryDocument) { confirmingRemoval = true }
                    .help(Wording.removeHelp)
                    .confirmationDialog(Wording.removeEverywhereQuestion(Wording.label(label)), isPresented: $confirmingRemoval) {
                        Button(Wording.remove, role: .destructive) { act(Wording.removeLabelAction) { try await $0.labels.remove($1) } }
                    } message: {
                        Text(Wording.removedMayComeBack)
                    }
                Button(Wording.removeForGoodEllipsis) { confirmingRemovalForGood = true }
                    .help(Wording.removeForGoodHelp)
                    .confirmationDialog(Wording.removeForGoodQuestion(Wording.label(label)), isPresented: $confirmingRemovalForGood) {
                        Button(Wording.removeForGood, role: .destructive) { act(Wording.removeLabelAction) { try await $0.labels.ignore($1) } }
                    } message: {
                        Text(Wording.removedForGoodFromLabels)
                    }
            }
            .buttonStyle(.borderless)
            .font(.callout)
        }
        .card()
        .onExitCommand { close() }
        // Merging asks first: nothing undoes it. Cancel, or Escape, leaves everything as it was, the field as typed.
        .confirmationDialog(asking.map { Wording.mergeQuestion(Wording.label(label), into: $0.target) } ?? "",
                            isPresented: Binding(get: { asking != nil }, set: { if !$0 { asking = nil } }), presenting: asking) { question in
            Button(Wording.merge, role: .destructive) { confirm(question) }
        } message: { question in
            Text(Wording.mergeMessage(documents: question.preview.documents, intoInUse: question.preview.intoInUse))
        }
        // Filled in when the card opens on a label, never as the page reloads, which would drop what is being typed.
        .task(id: label) { renamed = label.value }
        .task(id: [label.value] + others) {
            guard let limit = model.runtime?.config.labels.vocabulary.suggestionLimit else { return }
            candidates = LabelSimilarity.mostAlike(to: label.value, among: others, limit: limit)
        }
    }

    /// Rename to, its field holding the label as it is written, to be written anew.
    private var renaming: some View {
        VStack(alignment: .leading, spacing: Style.fieldRefusalSpacing) {
            HStack(spacing: Style.inlineControlSpacing) {
                Text(Wording.renameTo).foregroundStyle(.secondary)
                TextField(Wording.renameField(Wording.label(label)), text: $renamed)
                    .accessibilityLabel(Wording.renameField(Wording.label(label)))
                    .textFieldStyle(.roundedBorder).frame(width: Style.mergeFieldWidth)
                    .onSubmit { rename() }
                Button(Wording.rename) { rename() }.disabled(renameRefusal != nil)
            }
            .controlSize(.small)
            // The name as it is needs no word: the button is dimmed until it is written anew.
            if let renameRefusal, renamed.trimmingCharacters(in: .whitespaces) != label.value {
                Text(renameRefusal).font(.caption).foregroundStyle(Palette.attention).fixedSize(horizontal: false, vertical: true)
            }
        }
        .onChange(of: renamed, initial: true) { _, typed in
            renameRefusal = LabelError.refusal(ofMerging: label, into: typed)?.localizedDescription
        }
    }

    /// Merge into, with the labels in use most alike to it to choose from.
    private var merging: some View {
        VStack(alignment: .leading, spacing: Style.fieldRefusalSpacing) {
            HStack(spacing: Style.inlineControlSpacing) {
                Text(Wording.mergeInto).foregroundStyle(.secondary)
                // Named for what it is, whatever example of the label's kind it shows.
                TextField(Wording.mergeIntoField(Wording.label(label)), text: $into, prompt: Text(Wording.labelPrompt(label.kind)))
                    .accessibilityLabel(Wording.mergeIntoField(Wording.label(label)))
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
                Button(Wording.merge) { merge() }.disabled(target == nil || refusal != nil)
            }
            .controlSize(.small)
            if let refusal {
                Text(refusal).font(.caption).foregroundStyle(Palette.attention).fixedSize(horizontal: false, vertical: true)
            }
        }
        .onChange(of: target, initial: true) { _, typed in
            refusal = typed.flatMap { LabelError.refusal(ofMerging: label, into: $0) }?.localizedDescription
        }
    }

    /// The label written to merge into; nil while the field is blank.
    private var target: String? {
        let value = into.trimmingCharacters(in: .whitespaces)
        return value.isEmpty ? nil : value
    }

    /// What the user is asked before a merge or a rename into a label in use: the writing, and what Core says it changes.
    private struct MergeQuestion: Identifiable {
        let target: String
        let preview: LabelMergePreview
        /// Whether the label is written as `target` from now on (a rename) rather than merged into it, which History says
        /// otherwise and is made by the other action.
        let renaming: Bool
        var id: String { target }
    }

    /// Asks before merging into the label written, naming what changes. One it cannot be merged into stays in the field,
    /// under why, to be corrected.
    private func merge() {
        guard let target, LabelError.refusal(ofMerging: label, into: target) == nil else { return }
        ask(target, renaming: false)
    }

    /// Asks, from what Core says a merge or rename into `target` changes (`LabelActions.preview`); a rename into a writing
    /// no label has is made without asking, as it merges nothing.
    private func ask(_ target: String, renaming: Bool) {
        let label = label
        Task<Void, Never> {
            guard let preview = await model.load(Wording.previewMergeAction, { try await $0.labels.preview(merging: label, into: target) }) else { return }
            if renaming && !preview.intoInUse {
                await go(MergeQuestion(target: target, preview: preview, renaming: true))
            } else {
                asking = MergeQuestion(target: target, preview: preview, renaming: renaming)
            }
        }
    }

    private func confirm(_ question: MergeQuestion) {
        Task<Void, Never> { await go(question) }
    }

    /// Makes what was asked: the one action each of the two buttons has (`AppModel.mergeLabel`, `renameLabel`).
    private func go(_ question: MergeQuestion) async {
        if question.renaming {
            _ = await model.renameLabel(label, to: question.target)
        } else if await model.mergeLabel(label, into: question.target) {
            into = ""
        }
    }

    /// Renames the label to what is written, and opens it under its new name; into a label in use, after asking, as a merge
    /// is. One it cannot be renamed to stays in the field, under why.
    private func rename() {
        let value = renamed.trimmingCharacters(in: .whitespaces)
        guard LabelError.refusal(ofMerging: label, into: value) == nil else { return }
        ask(value, renaming: true)
    }

    /// Does `action` to the label, as the user asked.
    private func act(_ what: String, _ action: @escaping @Sendable (ArrumatorRuntime, DocumentLabel) async throws -> LabelActionOutcome) {
        let label = label
        Task<Void, Never> { await model.perform(what) { try await action($0, label) } }
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
