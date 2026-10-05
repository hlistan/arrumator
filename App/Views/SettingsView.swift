import AppKit
import ArrumatorCore
import ArrumatorRuntime
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
        .showsLastError()
    }
}

/// Binding into the settings in force that saves on change. `loaded` is what the page was opened with, which the
/// settings never go back from being, so the binding has a value without making one up.
@MainActor
func setting<T: Sendable>(_ model: AppModel, _ loaded: AppSettings, _ keyPath: any WritableKeyPath<AppSettings, T> & Sendable) -> Binding<T> {
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
                // Both as the app uses them, standardized alike, `~` written out and `/private` taken off
                // (`AppSettings.incomingURL`, the runtime's archive), never one as saved and the other as used.
                pathRow(Wording.incomingFolder, folder: model.settings?.incomingURL) { path in await model.update { $0.incomingPath = path } }
                pathRow(Wording.archiveFolder, folder: model.archive, busy: model.switchingArchive) { path in
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
                if notifying, let why = notNotifying {
                    Text(why).font(.caption).foregroundStyle(Palette.attention).fixedSize(horizontal: false, vertical: true)
                    if let settings = Self.notificationSettings {
                        Button(Wording.openNotificationSettings) { NSWorkspace.shared.open(settings) }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .task { await model.notifications.readPermission() }
        // Asked when a switch is turned on, so the answer is seen here rather than at the next filing.
        .onChange(of: notifying) { _, on in
            if on, let timeout = model.runtime?.config.interface.notificationAskTimeout {
                Task { await model.notifications.requestAuthorization(timeout: timeout) }
            }
        }
        // Read again when the user comes back, as from System Settings.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await model.notifications.readPermission() }
        }
    }

    /// Whether either switch asks for notifications.
    private var notifying: Bool {
        let current = model.settings ?? loaded
        return current.notifyOnFiled || current.notifyOnReview
    }

    /// Why no notification is shown although a switch is on: macOS does not let the app, or would not let it ask.
    private var notNotifying: String? {
        switch model.notifications.permission {
        case .refused: Wording.notificationsRefused
        case .unavailable: Wording.notificationsUnavailable
        case .allowed, .notAsked: nil
        }
    }

    /// System Settings › Notifications, by the scheme and identifier System Settings opens its panes by.
    private static let notificationSettings = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")

    private func pathRow(_ title: String, folder: URL?, busy: Bool = false, save: @escaping (String) async -> Void) -> some View {
        let path = folder?.path
        return LabeledContent(title) {
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
    @State private var confirmingReadAll = false
    /// What reading every document again queued, once asked.
    @State private var readAllMessage: String?

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
                Button(Wording.readAllAgain) { confirmingReadAll = true }
                    .confirmationDialog(Wording.readAllAgainQuestion, isPresented: $confirmingReadAll) {
                        // It replaces the labels the user corrected too.
                        Button(Wording.readAgain, role: .destructive) { Task { await readAll() } }
                    } message: {
                        Text(Wording.readAllAgainNote(profile: profileName))
                    }
                if let readAllMessage { Text(readAllMessage).font(.caption) }
            }
        }
        .formStyle(.grouped)
    }

    /// The name of the profile documents are read with, which reading them all again reads them with.
    private var profileName: String? {
        let settings = model.settings ?? loaded
        return settings.modelProfiles[settings.profile]?.name
    }

    private func readAll() async {
        let queued = await model.perform(Wording.readAllAgainAction) { try await $0.review.retryAll() }
        readAllMessage = queued.map { Wording.readAllAgainQueued($0.count) }
    }
}

/// Settings › Models: the Ollama server, then the profile documents and requests are read with and its three models, each
/// installed or to download, then every profile to edit (`ModelProfilesView`). Onboarding shows the server and the
/// models, a step each, so neither is out of sight below the other.
struct ModelSettingsView: View {
    /// What of Settings › Models a view shows.
    enum Part {
        /// The Ollama server: its state, its address and whether the app starts it.
        case server
        /// The profile in use and its models, installed or to download.
        case models
        /// Every profile, to edit.
        case profiles
    }

    @Environment(AppModel.self) private var model
    let loaded: AppSettings
    /// What it shows: Settings shows it all.
    var parts: Set<Part> = [.server, .models, .profiles]
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
            if parts.contains(.server) { serverSection }
            if parts.contains(.models) { modelsSection }
            if parts.contains(.profiles) { ModelProfilesView(profiles: profiles, installed: installed, downloads: downloads) }
        }
        .formStyle(.grouped)
        .task(id: model.settings) { await loadProfiles() }
        // Asked again when the models change, once Ollama answers, and when a download ends.
        .task(id: [inUse, model.session.ollama.isReady, downloads.finished] as [AnyHashable]) { await loadStatus() }
        .task(id: [model.session.ollama.isReady, downloads.finished] as [AnyHashable]) { await loadInstalled() }
        .onAppear { server = model.runtime?.ollama.baseURL.absoluteString ?? "" }
    }

    /// Whether the app starts the server when it is not running (`ArrumatorRuntime.management(for:at:)`): never one on
    /// another machine, nor one Management says never to start. The button then only checks it.
    private var startsOllama: Bool {
        model.runtime.map { ArrumatorRuntime.management(for: current, at: $0.ollama.baseURL) != .external } ?? false
    }

    private var serverSection: some View {
        Section(Wording.ollama) {
            LabeledContent(Wording.status, value: model.session.ollama.summary)
            HStack {
                TextField(Wording.server, text: $server).onSubmit { connect() }
                    .accessibilityLabel(Wording.server)
                Button(Wording.useServer) { connect() }.disabled(server == model.runtime?.ollama.baseURL.absoluteString)
            }
            .disabled(serverFromEnvironment)
            if let serverError { Text(serverError).font(.caption).foregroundStyle(Palette.attention) }
            Text(serverFromEnvironment ? Wording.serverFromEnvironment(RuntimeEnvironment.ollamaURLVariable) : Wording.ollamaServerNote)
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            // What the user is told of the server in use: plain HTTP across the network, a name trusted as local.
            ForEach(model.runtime.map { OllamaEndpoint.cautions(for: $0.ollama.baseURL) } ?? [], id: \.self) { caution in
                Text(caution.summary).font(.caption).foregroundStyle(Palette.attention).fixedSize(horizontal: false, vertical: true)
            }
            Picker(Wording.management, selection: setting(model, loaded, \.ollamaManagement)) {
                Text(Wording.launchOllamaApp).tag(OllamaManagement.launchApp)
                Text(Wording.spawnServe).tag(OllamaManagement.spawnServe)
                Text(Wording.neverStart).tag(OllamaManagement.external)
            }
            .disabled(!onThisMac)
            .help(Wording.managementOnThisMacOnly)
            if !onThisMac { Text(Wording.managementOnThisMacOnly).font(.caption).foregroundStyle(.secondary) }
            Button(startsOllama ? Wording.startOllama : Wording.checkOllama) {
                Task { _ = await model.runtime?.lifecycle.ensureRunning(); await loadStatus() }
            }
        }
    }

    private var modelsSection: some View {
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
                            ModelAvailability(name: name, status: status.first { $0.name == name }, downloads: downloads)
                        }
                    }
                }
                DownloadProgress(downloads: downloads, of: ModelProfile.roles.map(inUse.model(for:)))
            }
            Text(Wording.downloadNote)
                .font(.caption).foregroundStyle(.secondary)
        }
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
        guard model.session.ollama.isReady, let profile = inUse else { return }
        if let checked = await model.load(Wording.checkModelsAction, { try await $0.models.status(for: profile) }) { status = checked }
    }

    private func loadInstalled() async {
        guard parts.contains(.profiles), model.session.ollama.isReady else { return }
        if let listed = await model.load(Wording.checkModelsAction, { try await $0.models.installed() }) { installed = listed }
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
                        value: setting(model, loaded, \.traceRawRetentionDays), in: AppSettings.traceRawRetentionDaysRange, step: Style.retentionDaysStep)
                NamedToggle(Wording.includeText, isOn: $includeText)
                Text(Wording.includeTextNote).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
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
        let summary = await model.load(Wording.rebuildIndexAction) { try await $0.rebuildIndex() }
        rebuildMessage = summary.map { Wording.rebuilt($0.summary, queued: $0.queued) }
    }

    /// Asks where to save the diagnostics and saves them there. The panel opens beside the archive, where a task's export
    /// first opens, never wherever a panel was last left.
    private func export() async {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = Wording.diagnosticsFileName
        panel.directoryURL = model.archive?.deletingLastPathComponent()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let includeText = includeText
        let contents = await model.load(Wording.exportDiagnosticsAction) { try await $0.exportDiagnostics(to: url, includeDocumentText: includeText) }
        exportMessage = contents.map { Wording.exported(traces: $0.traces, logFiles: $0.logFiles.count) }
    }
}
