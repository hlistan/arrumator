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
                    ModelSettingsView(loaded: settings, editsProfiles: true).tabItem { Label(Wording.modelsTab, systemImage: "cpu") }
                    AdvancedSettings(loaded: settings).tabItem { Label(Wording.advancedTab, systemImage: "wrench.and.screwdriver") }
                    ProcessingLogView().tabItem { Label(Wording.processingLogTab, systemImage: "text.alignleft") }
                }
            } else {
                ProgressView()
            }
        }
        .frame(width: Style.settingsWindow.width, height: Style.settingsWindow.height)
        .showsLastError()
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
                NamedToggle(Wording.showInDock, isOn: setting(model, loaded, \.showInDock))
                if model.menuBarIconHidden {
                    Label(Wording.menuBarFull, systemImage: "exclamationmark.triangle")
                        .font(.callout).foregroundStyle(.secondary)
                }
                NamedToggle(Wording.openAtLogin, isOn: $loginItem).onChange(of: loginItem) { _, on in
                    do { try LoginItem.set(on) } catch {
                        loginError = error.localizedDescription
                        loginItem = LoginItem.isEnabled
                    }
                }
                if let loginError { Text(loginError).foregroundStyle(Palette.problem).font(.caption) }
                NamedToggle(Wording.pauseProcessing, isOn: Binding(get: { (model.settings ?? loaded).paused },
                                                         set: { paused in Task { await model.setPaused(paused) } }))
                NamedToggle(Wording.pauseOnBattery, isOn: setting(model, loaded, \.pauseOnBattery))
            }
            Section(Wording.notifications) {
                NamedToggle(Wording.notifyWhenFiled, isOn: setting(model, loaded, \.notifyOnFiled))
                NamedToggle(Wording.notifyWhenReview, isOn: setting(model, loaded, \.notifyOnReview))
            }
        }
        .formStyle(.grouped)
    }

    private func pathRow(_ title: String, path: String?, busy: Bool = false, save: @escaping (String) async -> Void) -> some View {
        LabeledContent(title) {
            HStack {
                if busy { ProgressView().controlSize(.small) }
                Text(path ?? Wording.noValue).lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary).help(path ?? "")
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
            Section {
                NamedToggle(Wording.renameFiles, isOn: setting(model, loaded, \.renameFiles))
                NamedToggle(Wording.transliterate, isOn: setting(model, loaded, \.transliterate))
            } header: {
                Text(Wording.files)
            } footer: {
                Text(Wording.filesFooter)
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Section(Wording.readingAgain) {
                Text(Wording.copiesFooter)
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
    }
}

/// Settings › Models: the Ollama server, then the profile documents and requests are read with and its three models, each
/// installed or to download. Onboarding shows this much; Settings also lists every profile to edit under it
/// (`ModelProfilesView`).
struct ModelSettingsView: View {
    @Environment(AppModel.self) private var model
    let loaded: AppSettings
    /// Whether every profile is listed to edit under the one in use, as Settings does and onboarding does not.
    var editsProfiles = false
    /// Every profile, as `ModelProfileActions.list()` orders them.
    @State private var profiles: [ModelProfileListing] = []
    /// Whether the models of the profile in use are installed; empty until Ollama has said.
    @State private var status: [ModelStatus] = []
    /// The installed models, to choose from for each role of a profile edited; nil until Ollama has said.
    @State private var installed: [InstalledModel]?
    @State private var downloads = ModelDownloads()
    @State private var server = ""
    @State private var serverError: String?

    private var onThisMac: Bool { model.runtime.map { OllamaEndpoint.isThisMac($0.ollama.baseURL) } ?? true }
    /// The environment names the server, so the one chosen here is not used while it does.
    private let serverFromEnvironment = RuntimeEnvironment.current.ollamaURL != nil
    private var current: AppSettings { model.settings ?? loaded }
    /// The profile Settings reads with: always one the settings list, as the store refuses any other.
    private var inUse: ModelProfile? { current.modelProfiles[current.profile] }

    var body: some View {
        Form {
            Section(Wording.ollama) {
                LabeledContent(Wording.status, value: model.ollama.summary)
                HStack {
                    TextField(Wording.server, text: $server).onSubmit { connect() }
                    Button(Wording.useServer) { connect() }.disabled(server == model.runtime?.ollama.baseURL.absoluteString)
                }
                .disabled(serverFromEnvironment)
                if let serverError { Text(serverError).font(.caption).foregroundStyle(Palette.attention) }
                Text(serverFromEnvironment ? Wording.serverFromEnvironment(RuntimeEnvironment.ollamaURLVariable) : Wording.ollamaServerNote)
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Picker(Wording.management, selection: setting(model, loaded, \.ollamaManagement)) {
                    Text(Wording.launchOllamaApp).tag(OllamaManagement.launchApp)
                    Text(Wording.spawnServe).tag(OllamaManagement.spawnServe)
                    Text(Wording.neverStart).tag(OllamaManagement.external)
                }
                .disabled(!onThisMac)
                .help(Wording.managementOnThisMacOnly)
                if !onThisMac { Text(Wording.managementOnThisMacOnly).font(.caption).foregroundStyle(.secondary) }
                Button(Wording.startOllama) { Task { _ = await model.runtime?.lifecycle.ensureRunning(); await loadStatus() } }
            }
            Section(Wording.modelsRun(at: model.runtime?.ollama.baseURL)) {
                if !profiles.isEmpty {
                    ProfileInUsePicker(inUse: current.profile, profiles: profiles)
                }
                if let inUse {
                    ForEach(ModelProfile.roles, id: \.self) { role in
                        let name = inUse.model(for: role)
                        LabeledContent(Wording.role(role)) {
                            HStack(spacing: Style.inlineControlSpacing) {
                                Text(name).textSelection(.enabled)
                                ModelAvailability(name: name, installed: status.first { $0.name == name }?.installed, downloads: downloads)
                            }
                        }
                    }
                    DownloadProgress(downloads: downloads, of: ModelProfile.roles.map(inUse.model(for:)))
                }
                Text(Wording.downloadNote)
                    .font(.caption).foregroundStyle(.secondary)
            }
            if editsProfiles { ModelProfilesView(profiles: profiles, installed: installed, downloads: downloads) }
        }
        .formStyle(.grouped)
        .task(id: model.settings) { await loadProfiles() }
        // Asked again when the models change, once Ollama answers, and when a download ends.
        .task(id: [inUse, model.ollama.isReady, downloads.finished] as [AnyHashable]) { await loadStatus() }
        .task(id: [model.ollama.isReady, downloads.finished] as [AnyHashable]) { await loadInstalled() }
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
                await loadStatus()
            } catch {
                serverError = error.localizedDescription
            }
        }
    }

    private func loadProfiles() async {
        guard let runtime = model.runtime else { return }
        profiles = await runtime.profiles.list()
    }

    private func loadStatus() async {
        guard model.ollama.isReady, let profile = inUse else { return }
        status = await model.load(Wording.checkModelsAction) { try await $0.models.status(for: profile) } ?? status
    }

    private func loadInstalled() async {
        guard editsProfiles, model.ollama.isReady else { return }
        installed = await model.load(Wording.checkModelsAction) { try await $0.models.installed() } ?? installed
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
                NamedToggle(Wording.includeText, isOn: $includeText)
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
