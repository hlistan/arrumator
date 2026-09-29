import AppKit
import ArrumatorCore
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings().tabItem { Label("General", systemImage: "gearshape") }
            FilingSettings().tabItem { Label("Filing", systemImage: "folder") }
            ModelSettingsView().tabItem { Label("Models", systemImage: "cpu") }
            AdvancedSettings().tabItem { Label("Advanced", systemImage: "wrench.and.screwdriver") }
            ProcessingLogView().tabItem { Label("Processing log", systemImage: "text.alignleft") }
        }
        .frame(width: 900, height: 620)
    }
}

/// Binding into `AppSettings` that saves on change.
@MainActor
func setting<T: Sendable>(_ model: AppModel, _ keyPath: WritableKeyPath<AppSettings, T> & Sendable, default value: T) -> Binding<T> {
    Binding(get: { model.settings?[keyPath: keyPath] ?? value },
            set: { newValue in Task { await model.update { $0[keyPath: keyPath] = newValue } } })
}

struct GeneralSettings: View {
    @Environment(AppModel.self) private var model
    @State private var loginItem = LoginItem.isEnabled
    @State private var loginError: String?

    var body: some View {
        Form {
            Section {
                pathRow("Incoming", path: model.settings?.incomingPath) { path in await model.update { $0.incomingPath = path } }
                pathRow("Archive", path: model.settings?.archivePath, busy: model.switchingArchive) { path in
                    await model.switchArchive(to: path)
                }
            } header: {
                Text("Folders")
            } footer: {
                Text("Each archive keeps its own senders and history. Choosing another archive files into it from now on; "
                    + "choosing this one again brings everything back.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Section("Background") {
                Toggle("Show icon in the Dock", isOn: setting(model, \.showInDock, default: true))
                if model.menuBarIconHidden {
                    Label("Your menu bar is full, so Arrumator's icon there is hidden. Keep the Dock icon on, or remove other menu bar items.",
                          systemImage: "exclamationmark.triangle")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Toggle("Open at login", isOn: $loginItem).onChange(of: loginItem) { _, on in
                    do { try LoginItem.set(on) } catch {
                        loginError = error.localizedDescription
                        loginItem = LoginItem.isEnabled
                    }
                }
                if let loginError { Text(loginError).foregroundStyle(.red).font(.caption) }
                Toggle("Pause processing", isOn: setting(model, \.paused, default: false))
                Toggle("Pause on battery when low", isOn: setting(model, \.pauseOnBattery, default: true))
            }
            Section("Notifications") {
                Toggle("When a document is filed", isOn: setting(model, \.notifyOnFiled, default: false))
                Toggle("When a document needs review", isOn: setting(model, \.notifyOnReview, default: true))
            }
        }
        .formStyle(.grouped)
    }

    private func pathRow(_ title: String, path: String?, busy: Bool = false, save: @escaping (String) async -> Void) -> some View {
        LabeledContent(title) {
            HStack {
                if busy { ProgressView().controlSize(.small) }
                Text(path ?? "—").lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                Button("Choose…") {
                    if let chosen = FolderPicker.choose(title: "Choose the \(title) folder", startingAt: path) { Task { await save(chosen) } }
                }
                .disabled(busy)
            }
        }
    }
}

struct FilingSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Form {
            Section("Files") {
                Toggle("Rename files", isOn: setting(model, \.renameFiles, default: true))
                Toggle("Transliterate names to Latin letters", isOn: setting(model, \.transliterate, default: false))
                Picker("Exact duplicates", selection: setting(model, \.duplicateAction, default: .fileInArchive)) {
                    Text("File copies into the archive").tag(DuplicateAction.fileInArchive)
                    Text("Leave copies in Incoming").tag(DuplicateAction.leaveInIncoming)
                }
            }
        }
        .formStyle(.grouped)
    }
}

struct ModelSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var status: [ModelStatus] = []
    @State private var downloading: String?
    @State private var progress: Double?
    @State private var message: String?
    @State private var server = ""
    @State private var serverError: String?

    private var onThisMac: Bool { model.runtime.map { OllamaEndpoint.isThisMac($0.ollama.baseURL) } ?? true }

    var body: some View {
        Form {
            Section("Ollama") {
                LabeledContent("Status", value: model.ollama.summary)
                HStack {
                    TextField("Server", text: $server).onSubmit { connect() }
                    Button("Use") { connect() }.disabled(server == model.runtime?.ollama.baseURL.absoluteString)
                }
                if let serverError { Text(serverError).font(.caption).foregroundStyle(Palette.attention) }
                Text(Wording.ollamaServerNote).font(.caption).foregroundStyle(.secondary)
                Picker("Management", selection: setting(model, \.ollamaManagement, default: .launchApp)) {
                    Text("Start the Ollama app when needed").tag(OllamaManagement.launchApp)
                    Text("Run 'ollama serve' myself (managed)").tag(OllamaManagement.spawnServe)
                    Text("Never start it").tag(OllamaManagement.external)
                }
                .disabled(!onThisMac)
                .help(Wording.managementOnThisMacOnly)
                Button("Start / check Ollama") { Task { _ = await model.runtime?.lifecycle.ensureRunning(); await load() } }
            }
            Section(Wording.modelsRun(at: model.runtime?.ollama.baseURL)) {
                Picker("Profile", selection: setting(model, \.models.profile, default: "standard")) {
                    ForEach(model.runtime?.config.modelProfiles.sorted { $0.key < $1.key } ?? [], id: \.key) { Text($0.value.label).tag($0.key) }
                }
                ForEach(status, id: \.self) { m in
                    HStack {
                        Image(systemName: m.installed ? "checkmark.circle.fill" : "arrow.down.circle").foregroundStyle(m.installed ? .green : .orange)
                        Text("\(m.role): \(m.name)")
                        Spacer()
                        if !m.installed {
                            Button(downloading == m.name ? "Downloading…" : "Download") { Task { await pull(m.name) } }
                                .disabled(downloading != nil)
                        }
                    }
                }
                if let progress { ProgressView(value: progress) }
                if let message { Text(message).font(.caption).foregroundStyle(.secondary) }
                Text("Downloading a model needs the internet once; reading and filing documents never does.")
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
        guard let runtime = model.runtime, let settings = model.settings, model.ollama.isReady,
              let resolved = try? runtime.config.models(for: settings.models) else { return }
        status = await model.load("Check models") { try await $0.models.status(for: resolved) } ?? []
    }

    private func pull(_ name: String) async {
        guard let runtime = model.runtime else { return }
        downloading = name
        defer { downloading = nil; progress = nil }
        do {
            for try await p in try await runtime.models.pull(name) {
                progress = p.fraction
                message = p.status
                if let error = p.error { throw OllamaError.http(status: 500, body: error) }
            }
            message = "\(name) installed"
        } catch {
            message = error.localizedDescription
        }
        await load()
    }
}

struct AdvancedSettings: View {
    @Environment(AppModel.self) private var model
    @State private var exportMessage: String?
    @State private var includeText = false
    @State private var rebuildMessage: String?
    @State private var confirmingRebuild = false

    var body: some View {
        Form {
            Section("Diagnostics") {
                Picker("Log detail", selection: setting(model, \.logLevel, default: .info)) {
                    ForEach(LogLevel.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                Stepper("Keep full model prompts for \(model.settings?.traceRawRetentionDays ?? 0) days",
                        value: setting(model, \.traceRawRetentionDays, default: 180), in: 1...3_650, step: 30)
                Toggle("Include document text in diagnostics", isOn: $includeText)
                Button("Export diagnostics…") { Task { await export() } }
                if let exportMessage { Text(exportMessage).font(.caption) }
            }
            Section("Index") {
                Text("Everything Arrumator knows is kept in Markdown files in the archive; the archive's index only holds "
                    + "them for search. Rebuilding reads the archive again, then reads each document's text again in the background.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Button("Rebuild Index From Archive…") { confirmingRebuild = true }
                    .confirmationDialog("Rebuild the index from the archive?", isPresented: $confirmingRebuild) {
                        Button("Rebuild") { Task { await rebuild() } }
                    } message: {
                        Text("Nothing in the archive changes. Search by words and by meaning fills in again as documents are read.")
                    }
                if let rebuildMessage { Text(rebuildMessage).font(.caption) }
            }
            Section("Files") {
                Button("Open logs folder") { if let dir = model.runtime?.paths.logsDirectory { model.open(dir.path) } }
                Button("Open data folder (indexes, settings, pipeline.json overrides)") {
                    if let dir = model.runtime?.paths.supportDirectory { model.open(dir.path) }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func rebuild() async {
        let summary = await model.load("Rebuild the index") { try await $0.records.rebuildIndex() }
        rebuildMessage = summary.map { "\($0.summary). \($0.queued) documents are being read again." }
    }

    private func export() async {
        guard let runtime = model.runtime, let settings = model.settings else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "arrumator-diagnostics.zip"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let exporter = DiagnosticsExporter(database: runtime.database, paths: runtime.paths, config: runtime.config.stats)
            let contents = try await exporter.export(to: url, doctor: await runtime.runDoctor(), settings: settings,
                                                     includeDocumentText: includeText)
            exportMessage = "Saved \(contents.traces) traces and \(contents.logFiles.count) log files."
        } catch {
            exportMessage = error.localizedDescription
        }
    }
}
