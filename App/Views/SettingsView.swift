import AppKit
import ArrumatorCore
import SwiftUI

/// The settings, shown once they are loaded: every value on these pages is the one in force, never one of the view's.
struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            if let settings = model.settings {
                TabView {
                    GeneralSettings(loaded: settings).tabItem { Label(Wording.generalTab, systemImage: "gearshape") }
                    FilingSettings(loaded: settings).tabItem { Label(Wording.filingTab, systemImage: "folder") }
                    ModelSettingsView(loaded: settings).tabItem { Label(Wording.modelsTab, systemImage: "cpu") }
                    AdvancedSettings(loaded: settings).tabItem { Label(Wording.advancedTab, systemImage: "wrench.and.screwdriver") }
                    ProcessingLogView().tabItem { Label(Wording.processingLogTab, systemImage: "text.alignleft") }
                }
            } else {
                ProgressView()
            }
        }
        .frame(width: Style.settingsWindow.width, height: Style.settingsWindow.height)
    }
}

/// Binding into the settings in force that saves on change. `loaded` is what the page was opened with, which the
/// settings never go back from being, so the binding has a value without making one up.
@MainActor
func setting<T: Sendable>(_ model: AppModel, _ loaded: AppSettings, _ keyPath: WritableKeyPath<AppSettings, T> & Sendable) -> Binding<T> {
    Binding(get: { (model.settings ?? loaded)[keyPath: keyPath] },
            set: { newValue in Task { await model.update { $0[keyPath: keyPath] = newValue } } })
}

struct GeneralSettings: View {
    @Environment(AppModel.self) private var model
    let loaded: AppSettings
    @State private var loginItem = LoginItem.isEnabled
    @State private var loginError: String?

    var body: some View {
        Form {
            Section {
                pathRow(Wording.incomingFolder, path: model.settings?.incomingPath) { path in await model.update { $0.incomingPath = path } }
                pathRow(Wording.archiveFolder, path: model.settings?.archivePath, busy: model.switchingArchive) { path in
                    await model.switchArchive(to: path)
                }
            } header: {
                Text(Wording.folders)
            } footer: {
                Text(Wording.foldersFooter)
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Section(Wording.background) {
                Toggle(Wording.showInDock, isOn: setting(model, loaded, \.showInDock))
                if model.menuBarIconHidden {
                    Label(Wording.menuBarFull, systemImage: "exclamationmark.triangle")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Toggle(Wording.openAtLogin, isOn: $loginItem).onChange(of: loginItem) { _, on in
                    do { try LoginItem.set(on) } catch {
                        loginError = error.localizedDescription
                        loginItem = LoginItem.isEnabled
                    }
                }
                if let loginError { Text(loginError).foregroundStyle(Palette.problem).font(.caption) }
                Toggle(Wording.pauseProcessing, isOn: Binding(get: { (model.settings ?? loaded).paused },
                                                         set: { paused in Task { await model.setPaused(paused) } }))
                Toggle(Wording.pauseOnBattery, isOn: setting(model, loaded, \.pauseOnBattery))
            }
            Section(Wording.notifications) {
                Toggle(Wording.notifyWhenFiled, isOn: setting(model, loaded, \.notifyOnFiled))
                Toggle(Wording.notifyWhenReview, isOn: setting(model, loaded, \.notifyOnReview))
            }
        }
        .formStyle(.grouped)
    }

    private func pathRow(_ title: String, path: String?, busy: Bool = false, save: @escaping (String) async -> Void) -> some View {
        LabeledContent(title) {
            HStack {
                if busy { ProgressView().controlSize(.small) }
                Text(path ?? Wording.noValue).lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                Button(Wording.choose) {
                    if let chosen = FolderPicker.choose(title: Wording.chooseFolder(title), startingAt: path) { Task { await save(chosen) } }
                }
                .disabled(busy)
            }
        }
    }
}

struct FilingSettings: View {
    @Environment(AppModel.self) private var model
    let loaded: AppSettings

    var body: some View {
        Form {
            Section(Wording.files) {
                Toggle(Wording.renameFiles, isOn: setting(model, loaded, \.renameFiles))
                Toggle(Wording.transliterate, isOn: setting(model, loaded, \.transliterate))
                Picker(Wording.exactDuplicates, selection: setting(model, loaded, \.duplicateAction)) {
                    Text(Wording.fileCopies).tag(DuplicateAction.fileInArchive)
                    Text(Wording.leaveCopies).tag(DuplicateAction.leaveInIncoming)
                }
            }
        }
        .formStyle(.grouped)
    }
}

struct ModelSettingsView: View {
    @Environment(AppModel.self) private var model
    let loaded: AppSettings
    @State private var status: [ModelStatus] = []
    @State private var downloading: String?
    @State private var progress: Double?
    @State private var message: String?
    @State private var server = ""
    @State private var serverError: String?

    private var onThisMac: Bool { model.runtime.map { OllamaEndpoint.isThisMac($0.ollama.baseURL) } ?? true }

    var body: some View {
        Form {
            Section(Wording.ollama) {
                LabeledContent(Wording.status, value: model.ollama.summary)
                HStack {
                    TextField(Wording.server, text: $server).onSubmit { connect() }
                    Button(Wording.useServer) { connect() }.disabled(server == model.runtime?.ollama.baseURL.absoluteString)
                }
                if let serverError { Text(serverError).font(.caption).foregroundStyle(Palette.attention) }
                Text(Wording.ollamaServerNote).font(.caption).foregroundStyle(.secondary)
                Picker(Wording.management, selection: setting(model, loaded, \.ollamaManagement)) {
                    Text(Wording.launchOllamaApp).tag(OllamaManagement.launchApp)
                    Text(Wording.spawnServe).tag(OllamaManagement.spawnServe)
                    Text(Wording.neverStart).tag(OllamaManagement.external)
                }
                .disabled(!onThisMac)
                .help(Wording.managementOnThisMacOnly)
                Button(Wording.startOllama) { Task { _ = await model.runtime?.lifecycle.ensureRunning(); await load() } }
            }
            Section(Wording.modelsRun(at: model.runtime?.ollama.baseURL)) {
                Picker(Wording.profile, selection: setting(model, loaded, \.models.profile)) {
                    ForEach(model.runtime?.config.modelProfiles.sorted { $0.key < $1.key } ?? [], id: \.key) { Text($0.value.label).tag($0.key) }
                }
                ForEach(status, id: \.self) { m in
                    HStack {
                        Image(systemName: m.installed ? "checkmark.circle.fill" : "arrow.down.circle").foregroundStyle(m.installed ? Palette.fine : Palette.attention)
                        Text(Wording.model(role: m.role.rawValue, name: m.name))
                        Spacer()
                        if !m.installed {
                            Button(downloading == m.name ? Wording.downloading : Wording.download) { Task { await pull(m.name) } }
                                .disabled(downloading != nil)
                        }
                    }
                }
                if let progress { ProgressView(value: progress) }
                if let message { Text(message).font(.caption).foregroundStyle(.secondary) }
                Text(Wording.downloadNote)
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .task(id: "\(model.settings?.models.profile ?? "")|\(model.ollama.isReady)") { await load() }
        .onAppear { server = model.runtime?.ollama.baseURL.absoluteString ?? "" }
    }

    /// Points the app at the server typed in, or says why it cannot.
    private func connect() {
        let address = server
        Task {
            guard let runtime = model.runtime else { return }
            do {
                try await runtime.useOllama(at: address)
                _ = await runtime.lifecycle.ensureRunning()
                serverError = nil
                server = runtime.ollama.baseURL.absoluteString
                model.settings = await runtime.settings.current
                await load()
            } catch {
                serverError = error.localizedDescription
            }
        }
    }

    private func load() async {
        guard model.ollama.isReady else { return }
        let selection = (model.settings ?? loaded).models
        status = await model.load(Wording.checkModelsAction) { try await $0.models.status(for: try $0.config.models(for: selection)) } ?? []
    }

    private func pull(_ name: String) async {
        guard let runtime = model.runtime else { return }
        downloading = name
        defer { downloading = nil; progress = nil }
        do {
            for try await p in try await runtime.models.pull(name) {
                progress = p.fraction
                message = p.status
            }
            message = Wording.installed(name)
        } catch {
            message = error.localizedDescription
        }
        await load()
    }
}

struct AdvancedSettings: View {
    @Environment(AppModel.self) private var model
    let loaded: AppSettings
    @State private var exportMessage: String?
    @State private var includeText = false
    @State private var rebuildMessage: String?
    @State private var confirmingRebuild = false

    var body: some View {
        Form {
            Section(Wording.diagnostics) {
                Picker(Wording.logDetail, selection: setting(model, loaded, \.logLevel)) {
                    ForEach(LogLevel.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                Stepper(Wording.keepPrompts(days: (model.settings ?? loaded).traceRawRetentionDays),
                        value: setting(model, loaded, \.traceRawRetentionDays), in: Style.retentionDays, step: Style.retentionDaysStep)
                Toggle(Wording.includeText, isOn: $includeText)
                Button(Wording.exportDiagnostics) { Task { await export() } }
                if let exportMessage { Text(exportMessage).font(.caption) }
            }
            Section(Wording.index) {
                Text(Wording.indexNote)
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Button(Wording.rebuildIndex) { confirmingRebuild = true }
                    .confirmationDialog(Wording.rebuildQuestion, isPresented: $confirmingRebuild) {
                        Button(Wording.rebuild) { Task { await rebuild() } }
                    } message: {
                        Text(Wording.rebuildNote)
                    }
                if let rebuildMessage { Text(rebuildMessage).font(.caption) }
            }
            Section(Wording.files) {
                Button(Wording.openLogsFolder) { if let dir = model.runtime?.paths.logsDirectory { model.open(dir.path) } }
                Button(Wording.openDataFolder) {
                    if let dir = model.runtime?.paths.supportDirectory { model.open(dir.path) }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func rebuild() async {
        let summary = await model.load(Wording.rebuildIndexAction) { try await $0.records.rebuildIndex() }
        rebuildMessage = summary.map { Wording.rebuilt($0.summary, queued: $0.queued) }
    }

    private func export() async {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = Wording.diagnosticsFileName
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let includeText = includeText
        let contents = await model.load(Wording.exportDiagnosticsAction) { try await $0.exportDiagnostics(to: url, includeDocumentText: includeText) }
        exportMessage = contents.map { Wording.exported(traces: $0.traces, logFiles: $0.logFiles.count) }
    }
}
