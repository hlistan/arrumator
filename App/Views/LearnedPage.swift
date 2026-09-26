import ArrumatorCore
import ArrumatorRuntime
import SwiftUI

/// What the app knows now, and a way to make it forget any of it: the documents it files by as examples of their
/// folders, the rules that formed, the senders it knows, and the suggestions waiting for a yes or no. Forgetting
/// something takes it off this page; History keeps the record of it.
struct LearnedPage: View {
    @Environment(AppModel.self) private var model
    @State private var examples: [LearnedExample] = []
    @State private var rules: [FilingRule] = []
    @State private var senders: [Correspondent] = []
    /// Every sender's name, for naming the sender a rule is about.
    @State private var senderNames: [Int64: String] = [:]
    @State private var proposals: [ProposalRecord] = []
    @State private var pages = 1
    /// The example whose document is open underneath it.
    @State private var openExample: Int64?
    @State private var openRule: Int64?
    @State private var openSender: Int64?

    private var days: [(title: String, examples: [LearnedExample])] {
        var out: [(title: String, examples: [LearnedExample])] = []
        for example in examples {
            let title = Wording.day(example.memory.createdAt)
            if out.last?.title == title { out[out.count - 1].examples.append(example) } else { out.append((title, [example])) }
        }
        return out
    }

    var body: some View {
        Page(.learned, notes: "Every filing and every correction teaches Arrumator. Documents it has filed become examples "
            + "that similar documents follow. Senders are who documents come from; once several filings from a sender "
            + "agree on a folder, a rule forms, and reliable rules file that sender's documents without asking the model. "
            + "Anything here can be forgotten.") {
            if !proposals.isEmpty {
                PageSection("Suggestions") {
                    ForEach(proposals) { proposal in
                        HStack {
                            ListRow(symbol: "lightbulb", tint: Palette.attention, title: proposal.title)
                            if let id = proposal.id {
                                Button("Accept") { Task { await model.perform("Accept") { try await $0.proposals.accept(id) } } }
                                Button("Dismiss") { Task { await model.perform("Dismiss") { try await $0.proposals.reject(id) } } }
                            }
                        }
                        .buttonStyle(.link)
                    }
                }
            }
            if examples.isEmpty {
                EmptyState(symbol: "graduationcap", text: "Nothing yet. Documents become examples as they are filed and corrected.")
            }
            ForEach(days, id: \.title) { day in
                PageSection(day.title) {
                    ForEach(day.examples) { example in
                        ExampleRow(example: example)
                            .onTapGesture { withAnimation(.snappy) { openExample = openExample == example.id ? nil : example.id } }
                        if openExample == example.id { DocumentCard(documentID: example.id) }
                    }
                }
            }
            if let pageSize = model.runtime?.config.interface.pageSize, examples.count == pages * pageSize {
                Button("Show More") { pages += 1 }.buttonStyle(.link)
            }
            PageSection("Rules") {
                if rules.isEmpty {
                    Text("No rules yet. They form once several filings agree.").foregroundStyle(.secondary).padding(.vertical, 6)
                }
                ForEach(rules) { rule in
                    RuleRow(rule: rule, senderNames: senderNames, open: openRule == rule.id)
                        .onTapGesture { withAnimation(.snappy) { openRule = openRule == rule.id ? nil : rule.id } }
                }
            }
            PageSection("Senders") {
                if senders.isEmpty {
                    Text("No senders yet. They are learned from the documents that arrive.").foregroundStyle(.secondary)
                        .padding(.vertical, 6)
                }
                ForEach(senders) { sender in
                    SenderRow(sender: sender, rules: rules.filter { $0.senderID == sender.id }, open: openSender == sender.id)
                        .onTapGesture { withAnimation(.snappy) { openSender = openSender == sender.id ? nil : sender.id } }
                }
            }
        }
        .task(id: "\(pages)|\(model.activity)") {
            let pages = pages
            examples = await model.load("Load what was learned") {
                try await $0.learningStore.examples(limit: pages * $0.config.interface.pageSize)
            } ?? []
            rules = await model.load("Load rules") { try await $0.learningStore.rules().filter { !$0.forgotten } } ?? []
            let all = await model.load("Load senders") { try await $0.learningStore.correspondents() } ?? []
            senderNames = Correspondent.names(all)
            senders = model.runtime.map { Array(all.sorted { $0.filedCount > $1.filedCount }.prefix($0.config.interface.pageSize)) } ?? []
            proposals = await model.load("Load suggestions") { try await $0.proposals.pending() } ?? []
        }
    }
}

/// A document the app files by: which folder it is an example of, and, on hover, a way to forget it, which takes the
/// row off the page.
private struct ExampleRow: View {
    @Environment(AppModel.self) private var model
    let example: LearnedExample
    @State private var hovering = false

    private var folder: String {
        model.taxonomy.flatMap { taxonomy in taxonomy.folder(id: example.memory.folderID).map { Wording.path(of: $0, in: taxonomy) } }
            ?? example.memory.folderCode
    }

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: example.document.status.symbol).foregroundStyle(example.document.status.tint).frame(width: 18)
            Text(example.document.filename).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 16)
            Text("Example of \(folder)").foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            if hovering {
                Button("Forget") {
                    let fact = example.fact
                    Task { await model.perform("Forget") { try await $0.learner.forget(fact) } }
                }
                .buttonStyle(.link)
                .help("Stop using this document as an example of where documents like it go")
            }
        }
        .padding(.horizontal, 8)
        .frame(minHeight: Style.rowHeight)
        .background(hovering ? Style.hover : .clear, in: .rect(cornerRadius: Style.rowCornerRadius))
        .contentShape(.rect)
        .onHover { hovering = $0 }
    }
}

/// A rule as a Things to-do: the checkbox switches it on or off; opening it shows when it applies and its record.
private struct RuleRow: View {
    @Environment(AppModel.self) private var model
    let rule: FilingRule
    let senderNames: [Int64: String]
    let open: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 9) {
                Toggle("", isOn: Binding(get: { rule.enabled }, set: save)).toggleStyle(.checkbox).labelsHidden()
                Text(rule.name).lineLimit(1).foregroundStyle(rule.enabled ? .primary : .secondary)
                Spacer(minLength: 16)
                Text("\(rule.support) agree · used \(rule.hits)×").foregroundStyle(.secondary)
            }
            if open {
                VStack(alignment: .leading, spacing: 4) {
                    Text("When " + rule.condition { senderNames[$0] })
                    Text("\(Format.percent(rule.reliability)) reliable · \(rule.contradictions) times it was wrong")
                        .foregroundStyle(.secondary)
                    Button("Forget Rule", role: .destructive) {
                        let id = rule.id
                        Task { await model.perform("Forget rule") { try await $0.learner.forget(.rule(id: id)) } }
                    }
                    .buttonStyle(.link)
                    .help("It stops placing documents and does not form again from the same filings")
                }
                .font(.callout)
                .padding(.leading, 27)
                .padding(.bottom, 6)
            }
        }
        .padding(.horizontal, 8)
        .frame(minHeight: Style.rowHeight)
        .contentShape(.rect)
    }

    /// Switching a rule by hand confirms it, so the app leaves it as the user set it.
    private func save(_ enabled: Bool) {
        var updated = rule
        updated.enabled = enabled
        updated.confirmed = true
        let changed = updated
        Task { await model.perform("Update rule") { try await $0.learningStore.saveRule(changed) } }
    }
}

/// A sender the app knows: how many of its filings it learned from and where they usually go; opened, its other names
/// (each of which can be forgotten), what identifies it and what that is for, the rules about it, and a way to forget
/// it altogether.
private struct SenderRow: View {
    @Environment(AppModel.self) private var model
    let sender: Correspondent
    let rules: [FilingRule]
    let open: Bool

    private var usualFolder: String? {
        sender.defaultFolderCode.flatMap { model.taxonomy?.path(ofCode: $0, separator: Wording.pathSeparator) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 9) {
                Image(systemName: "person.crop.square").foregroundStyle(.secondary).frame(width: 18)
                Text(sender.canonicalName).lineLimit(1)
                Spacer(minLength: 16)
                Text([sender.filedCount > 0 ? "\(Format.count(sender.filedCount, "filing")) learned" : nil,
                      usualFolder.map { "usually \($0)" }].compactMap { $0 }
                    .joined(separator: " · "))
                    .foregroundStyle(.secondary).lineLimit(1)
            }
            if open {
                VStack(alignment: .leading, spacing: 4) {
                    if !sender.aliases.isEmpty {
                        HStack(spacing: 6) {
                            Text("Also known as").foregroundStyle(.secondary)
                            ForEach(sender.aliases, id: \.self) { alias in
                                Button {
                                    let id = sender.id
                                    Task { await model.perform("Forget name") { try await $0.learner.forget(.alias(correspondentID: id, alias: alias)) } }
                                } label: {
                                    Label(alias, systemImage: "xmark").labelStyle(.titleAndIcon)
                                }
                                .buttonStyle(.bordered).controlSize(.small).help("Forget this name")
                            }
                        }
                    }
                    let recognisedBy = sender.stableKeys + sender.emailDomains.map { "@\($0)" } + sender.webDomains
                    if !recognisedBy.isEmpty {
                        Text("Recognised by " + recognisedBy.joined(separator: ", "))
                        Text(Wording.recognition(of: sender.canonicalName)).foregroundStyle(.secondary)
                    }
                    if rules.isEmpty {
                        Text(Wording.senderWithoutRules).foregroundStyle(.secondary)
                    } else {
                        Text("Rules").foregroundStyle(.secondary)
                        ForEach(rules) { rule in
                            Text(Wording.senderRule(rule, in: model.taxonomy)).foregroundStyle(rule.enabled ? .primary : .secondary)
                        }
                    }
                    Button("Forget Sender", role: .destructive) {
                        let id = sender.id
                        Task { await model.perform("Forget sender") { try await $0.learner.forget(.sender(correspondentID: id)) } }
                    }
                    .buttonStyle(.link)
                    .help("Forget its names, identifiers and usual folder, and the rules about it")
                }
                .font(.callout)
                .padding(.leading, 27)
                .padding(.bottom, 6)
            }
        }
        .padding(.horizontal, 8)
        .frame(minHeight: Style.rowHeight)
        .contentShape(.rect)
    }
}
