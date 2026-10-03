import ArrumatorCore

extension SettingsStore {
    /// A store over the settings at `paths`, waiting for another store's change as the bundled configuration says, on
    /// the system clock, as the app and every command make one.
    public static func opened(paths: AppPaths, mending: Bool = false) throws -> SettingsStore {
        try SettingsStore(paths: paths, config: PipelineConfig.bundledDefaults().settingsLock, time: SystemTime(), mending: mending)
    }
}
