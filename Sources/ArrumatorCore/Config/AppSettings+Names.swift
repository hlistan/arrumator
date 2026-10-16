import Foundation

/// The name the app shows each setting under, which History writes it by (`SettingsActions.summary`) instead of the key
/// `settings.json` stores it under. Each is an exhaustive `switch`, so a setting added without a name does not compile.
extension AppSettings.CodingKeys {
    /// What Settings, or the command line where Settings has no control for it, calls the setting.
    public var title: String {
        switch self {
        case .incomingPath: "Incoming folder"
        case .archivePath: "Archive folder"
        case .paused: "Pause filing"
        case .showInDock: "Show icon in the Dock"
        case .renameFiles: "Rename files"
        case .transliterate: "Transliterate names to Latin letters"
        case .profile: "Profile"
        case .modelProfiles: "Model profiles"
        case .ollamaURL: "Ollama server"
        case .ollamaManagement: "Ollama management"
        case .ollamaBinaryPath: "Ollama program"
        case .enableVLM: "Describe images"
        case .notifyOnFiled: "When a document is filed"
        case .notifyOnReview: "When a document needs you"
        case .pauseOnBattery: "Pause on battery when low"
        case .logLevel: "Log detail"
        case .traceRawRetentionDays: "Keep full model prompts"
        case .onboardingCompleted: "Setup finished"
        case .groupLabelsByKind: "Group labels by kind"
        case .taskEffort: "Effort of new search tasks"
        }
    }

    /// The group of Settings the control is under, when its title alone does not say what it is about.
    public var section: String? {
        switch self {
        case .notifyOnFiled, .notifyOnReview: "Notifications"
        case .incomingPath, .archivePath, .paused, .showInDock, .renameFiles, .transliterate, .profile, .modelProfiles, .ollamaURL,
             .ollamaManagement, .ollamaBinaryPath, .enableVLM, .pauseOnBattery, .logLevel, .traceRawRetentionDays, .onboardingCompleted,
             .groupLabelsByKind, .taskEffort: nil
        }
    }

    /// How History names the setting: under its group when it has one, as Settings shows it.
    public var historyName: String { section.map { "\($0) › \(title)" } ?? title }
}
