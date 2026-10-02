import ArrumatorCore
import ArrumatorRuntime
import SwiftUI

/// Settings › Models › Profiles: every profile as a row, its name with its reading model, the one in use and a changed
/// predefined one saying so, each opening in place to change its name and models; a predefined one that was changed can
/// be reset, a profile of the user's removed, and a new one starts as a copy of the one in use. Every change goes through
/// `ModelProfileActions`, which refuses what would leave the settings unusable, and the reason is shown.
struct ModelProfilesView: View {
    @Environment(AppModel.self) private var model
    /// Every profile, as `ModelProfileActions.list()` orders them.
    let profiles: [ModelProfileListing]
    /// The installed models, to choose from for each role; nil until Ollama has said.
    let installed: [InstalledModel]?
    let downloads: ModelDownloads
    /// The profile opened in place. One at a time, as in Things.
    @State private var open: String?
    @State private var adding = false
    @State private var newName = ""
    @FocusState private var namingNew: Bool

    var body: some View {
        Section {
            ForEach(profiles) { listing in
                if open == listing.id {
                    ProfileCard(listing: listing, installed: installed, downloads: downloads) { close(listing.id) }
                } else {
                    ProfileRow(listing: listing)
                        .onTapGesture { withAnimation(.snappy) { open = listing.id } }
                }
            }
            if adding {
                newProfile
            } else {
                Button(Wording.newProfile) { adding = true }.buttonStyle(.borderless)
            }
        } header: {
            Text(Wording.profiles)
        } footer: {
            Text(Wording.profilesNote(predefined: profiles.filter(\.predefined).map(\.profile.name)))
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Where a new profile is named, with what it starts as.
    private var newProfile: some View {
        VStack(alignment: .leading, spacing: Style.cardLabelRowSpacing) {
            HStack(spacing: Style.inlineControlSpacing) {
                TextField(Wording.newProfileName, text: $newName, prompt: Text(Wording.newProfileName))
                    .textFieldStyle(.roundedBorder).labelsHidden().multilineTextAlignment(.leading)
                    .focused($namingNew)
                    .onSubmit(add)
                    .onAppear { namingNew = true }
                Button(Wording.add, action: add).disabled(newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button(Wording.cancel, action: stopAdding)
            }
            Text(Wording.copiesProfile(profiles.first(where: \.inUse)?.profile.name))
                .font(.caption).foregroundStyle(.secondary)
        }
        .onExitCommand(perform: stopAdding)
    }

    /// Adds a copy of the profile in use under the name typed, and opens it to give it other models.
    private func add() {
        let name = newName
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        Task {
            guard let added = await model.changeSettings(Wording.addProfileAction, { try await $0.profiles.add(name: name) }) else { return }
            stopAdding()
            withAnimation(.snappy) { open = added.id }
        }
    }

    private func stopAdding() {
        adding = false
        newName = ""
    }

    private func close(_ id: String) {
        withAnimation(.snappy) { if open == id { open = nil } }
    }
}

/// A profile's row: its name, then quietly whether it is in use or changed, and the model that reads with it.
private struct ProfileRow: View {
    let listing: ModelProfileListing

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Style.profileNameSpacing) {
            Text(listing.profile.name)
            if let state = Wording.profileState(listing) { Text(state).foregroundStyle(.secondary) }
            Spacer(minLength: Style.rowDetailMinGap)
            Text(listing.profile.chatModel).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
        }
        .contentShape(.rect)
        .help(Wording.openProfileHelp)
    }
}

/// A profile opened in place: its name, and the model of each role, typed or chosen from the installed models that can
/// play it, with whether it is installed; Reset for a predefined profile that was changed, Remove for one of the user's
/// other than the one in use. What the user is typing is never replaced by what the profile says, and is saved when the
/// field is left or the card goes away.
private struct ProfileCard: View {
    @Environment(AppModel.self) private var model
    let listing: ModelProfileListing
    let installed: [InstalledModel]?
    let downloads: ModelDownloads
    let onClose: () -> Void
    @State private var name = ""
    @State private var models: [ModelRole: String] = [:]
    /// The profile as the fields last showed it saved, which what is typed is told apart from.
    @State private var shownProfile: ModelProfile?
    /// Whether the profile's models are installed; empty until Ollama has said.
    @State private var status: [ModelStatus] = []
    @State private var confirmingRemoval = false
    @FocusState private var editing: Field?

    /// What the user may be typing in.
    private enum Field: Hashable {
        case name
        case model(ModelRole)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Style.profileCardSpacing) {
            header
            Grid(alignment: .leading, horizontalSpacing: Style.cardGridColumnSpacing, verticalSpacing: Style.cardLabelRowSpacing) {
                ForEach(ModelProfile.roles, id: \.self) { role in
                    GridRow(alignment: .firstTextBaseline) {
                        Text(Wording.role(role)).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
                        field(role)
                    }
                    if role == .embedding {
                        GridRow(alignment: .firstTextBaseline) {
                            // An empty cell under the roles' names, which takes no room of its own.
                            Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                            Text(Wording.embeddingNote).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            DownloadProgress(downloads: downloads, of: ModelProfile.roles.map(listing.profile.model(for:)))
            if canReset || canRemove { actions }
        }
        .labelsHidden()
        .padding(.vertical, Style.profileCardPadding)
        .onExitCommand(perform: onClose)
        .onChange(of: listing, initial: true) { _, shown in show(shown) }
        // Closed with ✕ or Escape, another row or a new profile opened, the tab or the window left: what was typed and
        // not yet saved is saved rather than dropped.
        .onDisappear { save(typed) }
        // Asked again when the profile's models change, once Ollama answers, and when a download ends.
        .task(id: [listing.profile, model.ollama.isReady, downloads.finished] as [AnyHashable]) { await loadStatus() }
        .onChange(of: editing) { left, _ in
            if let left { save(left) }
        }
        .confirmationDialog(Wording.removeProfileQuestion(listing.profile.name), isPresented: $confirmingRemoval) {
            Button(Wording.removeProfileConfirm, role: .destructive) {
                let id = listing.id
                Task { if await model.changeSettings(Wording.removeProfileAction, { try await $0.profiles.remove(id) }) != nil { onClose() } }
            }
        } message: {
            Text(Wording.removeProfileNote)
        }
    }

    /// A predefined profile the user changed, which can be set back to the one Arrumator comes with.
    private var canReset: Bool { listing.predefined && listing.changed }
    /// A profile of the user's own; the predefined ones the bundled settings would bring back.
    private var canRemove: Bool { !listing.predefined }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: Style.profileNameSpacing) {
            TextField(Wording.name, text: $name, prompt: Text(Wording.name))
                .textFieldStyle(.plain)
                .font(.title3.weight(.semibold))
                .focused($editing, equals: .name)
                .onSubmit { editing = nil }
            if let state = Wording.profileState(listing) { Text(state).foregroundStyle(.secondary) }
            Spacer(minLength: 0)
            Button(action: onClose) { Image(systemName: "xmark") }
                .buttonStyle(.borderless).foregroundStyle(.secondary).help(Wording.close)
        }
    }

    /// The model of a role, typed, or chosen from the installed models that can play it, and whether the one saved is
    /// installed.
    private func field(_ role: ModelRole) -> some View {
        let saved = listing.profile.model(for: role)
        let choices = installed?.filter { $0.roles.contains(role) }.map(\.name) ?? []
        return HStack(spacing: Style.inlineControlSpacing) {
            TextField(Wording.role(role), text: Binding(get: { models[role] ?? "" }, set: { models[role] = $0 }), prompt: Text(Wording.modelPrompt))
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.leading)
                .focused($editing, equals: .model(role))
                .onSubmit { editing = nil }
            if !choices.isEmpty {
                Menu {
                    ForEach(choices, id: \.self) { choice in
                        Button(choice) {
                            models[role] = choice
                            save(.model(role))
                        }
                    }
                } label: {
                    Image(systemName: "chevron.down")
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help(Wording.chooseInstalledModel)
            }
            ModelAvailability(name: saved, installed: status.first { $0.name == saved }?.installed, downloads: downloads)
        }
    }

    private var actions: some View {
        HStack(spacing: Style.actionSpacing) {
            if canReset {
                Button(Wording.resetProfile) {
                    let id = listing.id
                    Task { await model.changeSettings(Wording.resetProfileAction) { try await $0.profiles.reset(id) } }
                }
                .help(Wording.resetProfileHelp)
            }
            Spacer()
            if canRemove {
                // The profile in use cannot be removed, so it is not offered, rather than refused once confirmed.
                Button(Wording.removeProfile) { confirmingRemoval = true }
                    .disabled(listing.inUse)
                    .help(listing.inUse ? Wording.removeProfileInUseHelp : Wording.removeProfileHelp)
            }
        }
        .buttonStyle(.borderless)
        .font(.callout)
    }

    /// Shows the profile as `shown` has it, but not over what the user is typing.
    private func show(_ shown: ModelProfileListing) {
        shownProfile = shown.profile
        if editing != .name { name = shown.profile.name }
        for role in ModelProfile.roles where editing != .model(role) {
            models[role] = shown.profile.model(for: role)
        }
    }

    /// What the fields say that the profile as last shown saved does not: what was typed and not yet saved, as every
    /// field the user is not in shows the profile as it is.
    private var typed: ModelProfileChange {
        let profile = shownProfile ?? listing.profile
        var change = ModelProfileChange(name: name == profile.name ? nil : name)
        for role in ModelProfile.roles {
            if let typed = models[role], typed != profile.model(for: role) { change.models[role] = typed }
        }
        return change
    }

    /// Saves what was typed in `field`, when it differs from the profile.
    private func save(_ field: Field) {
        let typed = typed
        switch field {
        case .name: save(ModelProfileChange(name: typed.name))
        case let .model(role): save(ModelProfileChange(models: typed.models.filter { $0.key == role }))
        }
    }

    /// Saves `change` unless it gives nothing; a refusal is shown, and the fields show the profile as it is again.
    private func save(_ change: ModelProfileChange) {
        guard !change.isEmpty else { return }
        let (id, before) = (listing.id, listing)
        Task {
            let saved = await model.changeSettings(Wording.changeProfileAction) { try await $0.profiles.update(id, change) }
            show(saved ?? before)
        }
    }

    private func loadStatus() async {
        guard model.ollama.isReady else { return }
        let profile = listing.profile
        status = await model.load(Wording.checkModelsAction) { try await $0.models.status(for: profile) } ?? status
    }
}

// MARK: The profile in use

/// The profile documents are read with, and the requests of search tasks without a profile of their own, chosen among
/// every profile: choosing another reads with it from then on (`ModelProfileActions.use`), and why one is refused is
/// shown. Settings › Models lists it as a row of its form, and the bar at the sidebar's foot as a menu by its name.
struct ProfileInUsePicker: View {
    @Environment(AppModel.self) private var model
    /// The id of the profile in use: always one the settings list, as the store refuses any other.
    let inUse: String
    /// Every profile, as `ModelProfileActions.list()` orders them.
    let profiles: [ModelProfileListing]

    var body: some View {
        Picker(Wording.profile, selection: Binding(get: { inUse }, set: { id in
            Task { await model.changeSettings(Wording.useProfileAction) { try await $0.profiles.use(id) } }
        })) {
            ForEach(profiles) { Text($0.profile.name).tag($0.id) }
        }
    }
}

// MARK: Models of a profile, installed or to download

/// Downloads the models the user asks for, one at a time, shared by every Download button in Settings › Models, so each
/// says which model is downloading and every view of a model's state looks again once a download ends. Downloading
/// needs the internet, so it starts only when the user presses Download (`ModelManager.pull`).
@Observable
final class ModelDownloads {
    /// The model downloading, or downloaded last.
    private(set) var model: String?
    private(set) var busy = false
    private(set) var progress: Double?
    /// What Ollama says of the download, then that the model is installed, or why the download failed.
    private(set) var message: String?
    /// How many downloads ended, so the views that say which models are installed ask again.
    private(set) var finished = 0

    func pull(_ name: String, with runtime: ArrumatorRuntime) async {
        guard !busy else { return }
        model = name
        busy = true
        message = nil
        defer {
            busy = false
            progress = nil
            finished += 1
        }
        do {
            for try await step in try await runtime.models.pull(name) {
                progress = step.fraction
                message = step.status
            }
            message = Wording.installed(name)
        } catch {
            message = error.localizedDescription
        }
    }
}

/// Whether a model is installed: a quiet mark when it is, a Download button when it is not, nothing until Ollama has said.
struct ModelAvailability: View {
    @Environment(AppModel.self) private var model
    let name: String
    /// nil until Ollama has said.
    let installed: Bool?
    let downloads: ModelDownloads

    var body: some View {
        if installed == true {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(Palette.fine).help(Wording.modelInstalled)
        } else if installed == false {
            Button(downloads.busy && downloads.model == name ? Wording.downloading : Wording.download) {
                guard let runtime = model.runtime else { return }
                Task { await downloads.pull(name, with: runtime) }
            }
            .disabled(downloads.busy)
        }
    }
}

/// How far the download of one of `models` got, and what came of it.
struct DownloadProgress: View {
    let downloads: ModelDownloads
    let models: [String]

    init(downloads: ModelDownloads, of models: [String]) {
        self.downloads = downloads
        self.models = models
    }

    var body: some View {
        if let downloading = downloads.model, models.contains(downloading) {
            if let progress = downloads.progress { ProgressView(value: progress) }
            if let message = downloads.message { Text(message).font(.caption).foregroundStyle(.secondary) }
        }
    }
}
