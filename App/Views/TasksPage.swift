import ArrumatorCore
import ArrumatorRuntime
import SwiftUI

/// Search tasks: a field to ask for documents in one's own words, with the effort and profile to read the request with,
/// then the tasks, those still in the queue first and the rest newest first. A task in the queue says what the queue
/// does with it, as its status says (`AppModel.taskQueue`): being read, with a spinner, and by which model, or what it
/// waits for. A task opens in place as a card with its documents arranged by their labels, to look over, add to, take
/// from and export (`SearchTaskActions`), and a conversation about them (`ConversationView`).
struct TasksPage: View {
    @Environment(AppModel.self) private var model
    @State private var tasks: [SearchTask] = []
    @State private var prompt = ""
    /// The id of the profile the next task is read by; nil to follow the one Settings uses.
    @State private var askProfile: String?
    /// Every profile, as Settings lists them; nil until they are read.
    @State private var profiles: [ModelProfileListing]?

    private var active: [SearchTask] { tasks.filter(\.state.isActive) }
    private var earlier: [SearchTask] { tasks.filter { !$0.state.isActive } }

    var body: some View {
        Page(.tasks, notes: Wording.tasksNotes) {
            HStack(alignment: .firstTextBaseline, spacing: Style.askSpacing) {
                TextField(Wording.askPrompt, text: $prompt, axis: .vertical)
                    .accessibilityLabel(Wording.requestField)
                    .lineLimit(1...Style.askMaxLines)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(ask)
                Button(Wording.find, action: ask).disabled(prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            if let settings = model.settings {
                HStack(spacing: Style.askSpacing) {
                    Text(Wording.readWith).foregroundStyle(.secondary)
                    // The effort chosen here is Settings' effort for new tasks, so the next one is asked with it too.
                    ReadingControls(effort: setting(model, settings, \.taskEffort), profile: $askProfile, profiles: profiles)
                }
                .font(.callout)
            }
            if tasks.isEmpty {
                EmptyState(symbol: Destination.tasks.symbol, text: Wording.noTasksYet)
            }
            // Built whole: the tasks are few, and an open task's card, with its documents and its conversation, can be
            // taller than the window, which a lazy stack's estimates of the rows it has not built cannot follow.
            if !active.isEmpty {
                PageSection(Wording.inProgress, lazily: false) { ForEach(active) { row($0) } }
            }
            if !earlier.isEmpty {
                PageSection(Wording.earlierTasks, lazily: false) { ForEach(earlier) { row($0) } }
            }
        }
        // Reloaded when the queue takes a task to read, too, which History does not record.
        .task(id: model.taskActivity) { await load() }
        .task(id: model.settings) { await loadProfiles() }
    }

    @ViewBuilder private func row(_ task: SearchTask) -> some View {
        if model.session.openTask == task.id {
            TaskCard(taskID: task.id, profiles: profiles) { if model.session.openTask == task.id { model.session.openTask = nil } }
        } else {
            let progress = model.session.taskQueue.progress(of: task)
            // While its request is not read, what the conversation's queue does with its questions (`progress(ofTask:)`).
            let question = progress == nil ? model.session.conversation.progress(ofTask: task.id) : nil
            ListRow(symbol: task.state.symbol, tint: task.state.tint, title: task.name,
                    detail: question.map(Wording.questionRow) ?? Wording.taskOutcome(task, progress: progress),
                    subtitle: task.name == task.prompt ? nil : task.prompt, busy: progress?.isReading == true || question?.isAnswering == true)
                .rowAction { withAnimation(.snappy) { model.session.openTask = task.id } }
        }
    }

    /// Asks for a task with what was typed. A request that is refused, such as one given a profile removed meanwhile,
    /// says why and is given back to be asked again, unless something else has been typed since.
    private func ask() {
        let typed = prompt
        let asked = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !asked.isEmpty else { return }
        prompt = ""
        let (effort, profile) = (model.settings?.taskEffort, askProfile)
        Task<Void, Never> {
            guard let task = await model.load(Wording.askAction, {
                try await $0.searchTasks.create(prompt: asked, effort: effort, profile: profile)
            }) else {
                if prompt.isEmpty { prompt = typed }
                return
            }
            await load()
            model.session.openTask = task.id
        }
    }

    private func load() async {
        if let read = await model.load(Wording.loadTasksAction, { try await $0.searchTasks.store.tasks() }) { tasks = read }
    }

    /// Reads the profiles again; one chosen for the next task that the settings no longer list gives way to the one
    /// Settings uses, rather than staying chosen for a request it would refuse.
    private func loadProfiles() async {
        guard let runtime = model.runtime else { return }
        let listed = await runtime.profiles.list()
        profiles = listed
        if let chosen = askProfile, !listed.contains(where: { $0.id == chosen }) { askProfile = nil }
    }
}

/// How a request is read: the effort, how much the model thinks before it answers, as presets side by side; and a menu
/// of the profile whose model reads it, Settings' profile, whichever that is when the request is read, or one of its own.
struct ReadingControls: View {
    @Binding var effort: TaskEffort
    /// The id of the profile that reads the request; nil to follow the one Settings uses.
    @Binding var profile: String?
    /// Every profile, as Settings lists them; nil until they are read.
    let profiles: [ModelProfileListing]?

    var body: some View {
        HStack(spacing: Style.readingSpacing) {
            Picker(Wording.effort, selection: $effort) {
                ForEach(TaskEffort.allCases, id: \.self) { Text(Wording.effort($0)).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
            .help(Wording.effortHelp)
            Picker(Wording.profile, selection: $profile) {
                Text(Wording.settingsProfile(profiles?.first(where: \.inUse)?.profile.name)).tag(String?.none)
                Divider()
                ForEach(profiles ?? []) { Text(Wording.profileChoice($0.profile)).tag(String?.some($0.id)) }
                // A profile the settings no longer list stays chosen, saying so, until the task is given another.
                if let profile, !(profiles ?? []).contains(where: { $0.id == profile }) {
                    Text(profiles == nil ? profile : Wording.profileGone(profile)).tag(String?.some(profile))
                }
            }
            .pickerStyle(.menu).labelsHidden().frame(maxWidth: Style.profileMenuMaxWidth)
            .help(Wording.readingProfileHelp)
        }
        .controlSize(.small)
    }
}

/// A task opened in place: while it is in the queue, what the queue does with it (`TaskProgressLine`); what it asks for,
/// with what effort and by which profile, and how the model read it; its name, effort, profile and arrangement to change;
/// then either its documents, arranged by their labels, each to take out, with ways to add more and to export them and
/// every export made of them, or the conversation about them (`ConversationView`), answered with the same effort and
/// profile.
struct TaskCard: View {
    @Environment(AppModel.self) private var model
    let taskID: Int64
    /// Every profile, as Settings lists them; nil until they are read.
    let profiles: [ModelProfileListing]?
    let onClose: () -> Void
    @State private var detail: SearchTaskDetail?
    /// The set's documents as its rows show them, by their numbers, worked out when the task is read.
    @State private var listed: [Int64: ListedDocument] = [:]
    /// The exports still where they were made, as the disk said when the task was last read.
    @State private var exportsThere: Set<String> = []
    @State private var name = ""
    @State private var prompt = ""
    @State private var confirmingRemoval = false
    @FocusState private var editingName: Bool
    @FocusState private var editingPrompt: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Style.taskCardSpacing) {
            if let detail {
                header(detail.task)
                if let progress = model.session.taskQueue.progress(of: detail.task) { TaskProgressLine(progress: progress) }
                request(detail.task)
                Picker(Wording.documentsSection, selection: section) {
                    Text(Wording.documentsSection).tag(Section.documents)
                    Text(Wording.conversationSection).tag(Section.conversation)
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
                switch section.wrappedValue {
                case .documents:
                    if detail.task.state == .ready && detail.tree.count == 0 {
                        Text(Wording.nothingFound).foregroundStyle(.secondary)
                    }
                    SetLevel(group: detail.tree, taskID: taskID, listed: listed)
                    actions(detail.task)
                    exports(detail.task)
                case .conversation:
                    ConversationView(task: detail.task)
                }
            } else {
                ProgressView().frame(maxWidth: .infinity)
            }
        }
        .card()
        .onExitCommand { withAnimation(.snappy) { onClose() } }
        .task(id: model.taskActivity) { await load() }
        .onChange(of: editingName) { wasEditing, _ in
            // Left as it was, the name is not sent: Core would take it for no change anyway (`SearchTaskActions.update`).
            if wasEditing, name != detail?.task.name { change(SearchTaskChange(title: name)) }
        }
        .confirmationDialog(Wording.removeTaskQuestion(detail?.task.name ?? ""), isPresented: $confirmingRemoval) {
            Button(Wording.removeTaskConfirm, role: .destructive) {
                let id = taskID
                Task<Void, Never> { await model.perform(Wording.removeTaskAction) { try await $0.searchTasks.delete(id) } }
            }
        } message: {
            Text(Wording.removeTaskNote)
        }
    }

    /// What the card shows below what the task asks for.
    enum Section: Hashable {
        case documents, conversation
    }

    /// What the card shows, its documents until the user chooses otherwise, kept by the session
    /// (`ArchiveSession.taskCardSections`) so the choice outlasts the card.
    private var section: Binding<Section> {
        let (session, id) = (model.session, taskID)
        return Binding(get: { session.taskCardSections[id] ?? .documents }, set: { session.taskCardSections[id] = $0 })
    }

    private func header(_ task: SearchTask) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Image(systemName: task.state.symbol).foregroundStyle(task.state.tint)
            TextField(Wording.name, text: $name)
                .accessibilityLabel(Wording.name)
                .textFieldStyle(.plain)
                .font(.title3.weight(.semibold))
                // A plain field is as tall as its line, which cuts the descenders of a large font.
                .padding(.vertical, Style.titleFieldPadding)
                .focused($editingName)
                .onSubmit { editingName = false }
            Spacer(minLength: 0)
            Button { withAnimation(.snappy) { onClose() } } label: { Image(systemName: "xmark") }
                .buttonStyle(.borderless).foregroundStyle(.secondary).help(Wording.close)
                .accessibilityLabel(Wording.closeNamed(task.name))
        }
    }

    /// What was asked, how the model read it, and what the set is arranged by.
    private func request(_ task: SearchTask) -> some View {
        Grid(alignment: .leading, horizontalSpacing: Style.cardGridColumnSpacing, verticalSpacing: Style.cardLabelRowSpacing) {
            GridRow(alignment: .firstTextBaseline) {
                label(Wording.asked)
                HStack(alignment: .firstTextBaseline, spacing: Style.inlineControlSpacing) {
                    TextField(Wording.askPrompt, text: $prompt, axis: .vertical)
                        .accessibilityLabel(Wording.requestField)
                        .lineLimit(1...Style.askMaxLines)
                        .textFieldStyle(.roundedBorder)
                        .focused($editingPrompt)
                        .onSubmit { change(SearchTaskChange(prompt: prompt)) }
                    Button(Wording.findAgain) {
                        if prompt != task.prompt {
                            change(SearchTaskChange(prompt: prompt))
                        } else {
                            let id = taskID
                            Task<Void, Never> { await model.perform(Wording.findAgainAction) { _ = try await $0.searchTasks.retry(id) } }
                        }
                    }
                    .help(Wording.findAgainHelp)
                    .disabled(task.state.isActive)
                }
                .controlSize(.small)
            }
            GridRow(alignment: .firstTextBaseline) {
                label(Wording.readWith)
                HStack(spacing: Style.readingSpacing) {
                    // Another effort or profile reads the request again; none gives the task back to Settings' profile.
                    ReadingControls(effort: Binding(get: { task.effort }, set: { change(SearchTaskChange(effort: $0)) }),
                                    profile: Binding(get: { task.profile }, set: { change(SearchTaskChange(profile: $0 ?? "")) }),
                                    profiles: profiles)
                    if let last = task.model { Text(Wording.lastReadBy(last)).font(.callout).foregroundStyle(.secondary) }
                }
            }
            if let plan = task.plan {
                GridRow(alignment: .firstTextBaseline) {
                    label(Wording.lookedFor)
                    Text(Wording.plan(plan)).textSelection(.enabled)
                }
            }
            if let problem = task.problem {
                GridRow(alignment: .firstTextBaseline) {
                    label("")
                    Text(problem).foregroundStyle(Palette.attention).fixedSize(horizontal: false, vertical: true)
                }
            }
            GridRow(alignment: .firstTextBaseline) {
                label(Wording.arrangedBy)
                grouping(task)
            }
        }
    }

    /// The kinds the set is arranged by, each to take away, and a menu to add a level or go back to what was asked.
    private func grouping(_ task: SearchTask) -> some View {
        HStack(spacing: Style.groupingSpacing) {
            if task.grouping.isEmpty { Text(Wording.notArranged).foregroundStyle(.secondary) }
            ForEach(Array(task.grouping.enumerated()), id: \.element) { index, kind in
                if index > 0 { Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary) }
                HStack(spacing: Style.chipContentSpacing) {
                    Text(Wording.labelKind(kind)).foregroundStyle(Palette.labelKind(kind))
                    Button { change(SearchTaskChange(grouping: .by(task.grouping.filter { $0 != kind }))) } label: {
                        Image(systemName: "xmark.circle.fill").accessibilityLabel(Wording.stopArrangingBy(Wording.labelKind(kind)))
                    }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                }
                .padding(Style.labelChipInsets)
                .background(Style.hover, in: .capsule)
            }
            Menu {
                if task.grouping.count < (model.runtime?.config.tasks.maxGroupingDepth ?? 0) {
                    ForEach(LabelKind.allCases.filter { !task.grouping.contains($0) }, id: \.self) { kind in
                        Button(Wording.labelKind(kind)) { change(SearchTaskChange(grouping: .by(task.grouping + [kind]))) }
                    }
                }
                if task.groupedByUser {
                    Divider()
                    Button(Wording.arrangeAsAsked) { change(SearchTaskChange(grouping: .asAsked)) }.help(Wording.arrangeAsAskedHelp)
                }
            } label: {
                Image(systemName: "plus.circle")
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .help(Wording.addLevel).accessibilityLabel(Wording.addLevel)
        }
        .font(.callout)
    }

    private func actions(_ task: SearchTask) -> some View {
        HStack(spacing: Style.actionSpacing) {
            Button(Wording.addDocuments) { model.collect(for: task) }.help(Wording.addDocumentsHelp)
            Menu(Wording.exportMenu) {
                Button(Wording.exportToFolder) { export(.folder) }
                Button(Wording.exportAsZip) { export(.zip) }
            }
            .fixedSize()
            .disabled(task.documents.isEmpty)
            Spacer()
            Button(Wording.removeTask) { confirmingRemoval = true }
        }
        .buttonStyle(.borderless)
        .font(.callout)
    }

    /// Every export of the set, the newest first, each to show in Finder while it is there.
    @ViewBuilder private func exports(_ task: SearchTask) -> some View {
        if !task.exports.isEmpty {
            VStack(alignment: .leading, spacing: Style.cardReadingRowSpacing) {
                Text(Wording.exportsHeading).foregroundStyle(.secondary)
                ForEach(task.exports.reversed()) { export in
                    let there = exportsThere.contains(export.path)
                    HStack(spacing: Style.inlineControlSpacing) {
                        Image(systemName: export.format == .zip ? "doc.zipper" : "folder").foregroundStyle(.secondary)
                        Text(Wording.export(export))
                        Text(URL(fileURLWithPath: export.path).lastPathComponent).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        if there {
                            Button(Wording.showInFinder) { model.reveal(export.path) }.buttonStyle(.borderless)
                        } else {
                            Text(Wording.noLongerThere).foregroundStyle(.tertiary)
                        }
                    }
                    .help(export.path)
                }
            }
            .font(.callout)
        }
    }

    private func label(_ text: String) -> some View {
        Text(text).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
    }

    // MARK: Changes

    private func change(_ change: SearchTaskChange) {
        let id = taskID
        Task<Void, Never> { await model.perform(Wording.changeTaskAction) { _ = try await $0.searchTasks.update(id, change) } }
    }

    /// Asks where, exports there, and shows the export in Finder. The panel opens where the task was last exported to, or
    /// beside the archive, never wherever a panel was last left.
    private func export(_ format: ExportFormat) {
        let last = detail?.task.exports.last.map { URL(fileURLWithPath: $0.path).deletingLastPathComponent().path }
        let start = last ?? model.archive?.deletingLastPathComponent().path
        guard let path = FolderPicker.choose(title: Wording.chooseExportFolder, startingAt: start) else { return }
        let id = taskID
        Task<Void, Never> {
            guard let export = await model.load(Wording.exportAction, {
                try await $0.searchTasks.export(id, to: URL(fileURLWithPath: path, isDirectory: true), format: format)
            }) else { return }
            model.reveal(export.path)
        }
    }

    private func load() async {
        let id = taskID
        guard let read = await model.load(Wording.loadTaskAction, { try await $0.searchTasks.store.detail(id: id) }) else { return }
        detail = read
        guard let read else { return }
        listed = Dictionary(model.listed(read.tree.allDocuments).compactMap { row in row.id.map { ($0, row) } }, uniquingKeysWith: { first, _ in first })
        exportsThere = Set(read.task.exports.map(\.path).filter { FileManager.default.fileExists(atPath: $0) })
        let task = read.task
        // What the user is typing is not replaced by what the task says.
        if !editingName { name = task.name }
        if !editingPrompt { prompt = task.prompt }
    }
}

/// What the queue does with a task, at the top of its card in place of the documents not found yet: a spinner and by
/// which model its request is being read, with how long once that is more than a moment, or what it waits for, Ollama
/// marked as a notice. How long counts on by itself from when the queue began the reading, without reading the index
/// again; the line gives way to what the reading found, or why it failed, once it ends.
private struct TaskProgressLine: View {
    let progress: SearchTaskProgress

    var body: some View {
        if case .waitingForOllama = progress {
            Notice(text: Wording.taskProgressLine(progress))
        } else {
            HStack(spacing: Style.noticeSpacing) {
                ProgressView().controlSize(.small)
                if case let .reading(reading?) = progress {
                    TimelineView(.periodic(from: reading.since, by: Style.readingTimeTick)) { context in
                        let elapsed = context.date.timeIntervalSince(reading.since)
                        Text(Wording.taskProgressLine(progress, elapsed: elapsed >= Style.readingTimeShownAfter ? elapsed : nil))
                    }
                } else {
                    Text(Wording.taskProgressLine(progress))
                }
                Spacer()
            }
            .font(.callout)
            .foregroundStyle(.secondary)
        }
    }
}

/// One level of a task's set: a heading for each group of the level's kind, which folds away, with the level below it,
/// and the documents at the bottom, each to take out of the set.
private struct SetLevel: View {
    let group: LabelGroup
    let taskID: Int64
    let listed: [Int64: ListedDocument]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // A group is the label its documents share, one per value in a level, and keeps what is folded as the set
            // changes around it.
            ForEach(group.groups, id: \.value) { group in
                SetGroup(group: group, taskID: taskID, listed: listed)
            }
            ForEach(group.documents, id: \.id) { document in
                if let id = document.id, let row = listed[id] { SetDocument(document: row, taskID: taskID) }
            }
        }
    }
}

private struct SetGroup: View {
    let group: LabelGroup
    let taskID: Int64
    let listed: [Int64: ListedDocument]
    @State private var collapsed = false

    var body: some View {
        DisclosureGroup(isExpanded: Binding(get: { !collapsed }, set: { collapsed = !$0 })) {
            SetLevel(group: group, taskID: taskID, listed: listed).padding(.leading, Style.setLevelIndent)
        } label: {
            HStack {
                Text(Wording.group(group)).fontWeight(.medium)
                    .foregroundStyle(group.value == nil ? .secondary : .primary)
                Spacer()
                Text(String(group.count)).foregroundStyle(.secondary)
            }
        }
    }
}

/// A document of a task's set: its name, where it is and its labels; under the pointer, a × takes it out.
private struct SetDocument: View {
    @Environment(AppModel.self) private var model
    let document: ListedDocument
    let taskID: Int64
    @State private var hovering = false

    var body: some View {
        let record = document.record
        HStack(spacing: Style.rowAccessorySpacing) {
            ListRow(symbol: record.status.symbol, tint: record.status.tint, title: record.filename, detail: document.detail,
                    subtitle: document.labels)
                .openAction { model.open(record.path) }
                .help(Wording.doubleClickToOpen)
            Button(action: takeOut) {
                Image(systemName: "xmark.circle.fill").accessibilityLabel(Wording.takeOutNamed(record.filename))
            }
            .buttonStyle(.plain).foregroundStyle(.secondary).help(Wording.takeOutHelp)
            .opacity(hovering ? 1 : 0)
        }
        .onHover { hovering = $0 }
        .accessibilityAction(named: Wording.takeOut, takeOut)
        .contextMenu { Button(Wording.takeOut, action: takeOut) }
    }

    private func takeOut() {
        guard let id = document.id else { return }
        let task = taskID
        Task<Void, Never> { await model.perform(Wording.takeOutOfTaskAction) { _ = try await $0.searchTasks.remove(task, documents: [id]) } }
    }
}

/// Heads the pages the sidebar's labels narrow documents down on while documents are added to a task: which task, a way
/// to add every document with the labels chosen, and a way back to the task.
struct CollectingBar: View {
    @Environment(AppModel.self) private var model
    let task: SearchTask

    var body: some View {
        HStack(spacing: Style.noticeSpacing) {
            Image(systemName: Destination.tasks.symbol).foregroundStyle(Palette.tasksList)
            Text(Wording.addingTo(task.name)).foregroundStyle(.secondary)
            Spacer()
            if !model.session.labelSelection.isEmpty {
                Button(Wording.addAllShown) {
                    let (id, labels) = (task.id, model.session.labelSelection)
                    Task<Void, Never> { await model.perform(Wording.addToTaskAction) { _ = try await $0.searchTasks.add(id, labelled: labels) } }
                }
                .buttonStyle(.link)
            }
            Button(Wording.doneAdding) { model.finishCollecting() }
        }
        .font(.callout)
    }
}

/// The button beside a document's row while documents are added to a task: in the set, or to add to it.
struct CollectToggle: View {
    @Environment(AppModel.self) private var model
    let task: SearchTask
    let document: Int64
    /// The document's file name, which the button names to VoiceOver, as every row on the page has a button alike.
    let name: String

    var body: some View {
        let inSet = task.documents.contains(document)
        Button {
            let id = task.id
            Task<Void, Never> {
                await model.perform(inSet ? Wording.takeOutOfTaskAction : Wording.addToTaskAction) { runtime in
                    if inSet { _ = try await runtime.searchTasks.remove(id, documents: [document]) } else {
                        _ = try await runtime.searchTasks.add(id, documents: [document])
                    }
                }
            }
        } label: {
            Image(systemName: inSet ? "checkmark.circle.fill" : "plus.circle")
                .foregroundStyle(inSet ? Palette.tasksList : .secondary)
        }
        .buttonStyle(.plain)
        .help(inSet ? Wording.inTaskHelp : Wording.addToTaskHelp)
        .accessibilityLabel(inSet ? Wording.takeOutNamed(name) : Wording.addToTaskNamed(name))
    }
}
