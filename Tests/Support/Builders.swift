import ArrumatorCore

/// Record files as the user, by hand, may leave them, for the tests of reading them back and of rebuilding from them.
public enum TestRecordFiles {
    /// A list of documents with none in it.
    public static let emptyList = "---\narrumator: 1\nentries: []\n---\n"

    /// A list of documents broken by hand: its front matter is no longer YAML.
    public static let brokenList = broken(emptyList)

    /// A list of one document, filed as `file` in the list's folder.
    public static func list(of file: String) -> String {
        """
        ---
        arrumator: 1
        entries:
        - id: 1
          uid: 5B7A8F4E-0000-0000-0000-000000000001
          file: \(file)
          original_name: \(file)
          added: 2026-07-05T10:00:00Z
          filed: 2026-07-05T10:01:00Z
          status: filed
          content_type: public.plain-text
          size: \(file.utf8.count)
          sha256: \(file)
        ---

        """
    }

    /// A record file's `text` with its front matter no longer valid YAML, as a slip of the keyboard leaves it.
    public static func broken(_ text: String) -> String { text.replacingOccurrences(of: breakingWhat, with: breakingInto) }

    /// `text` broken as `broken` breaks it, corrected again.
    public static func mended(_ text: String) -> String { text.replacingOccurrences(of: breakingInto, with: breakingWhat) }

    private static let breakingWhat = "entries:"
    private static let breakingInto = "entries: [unclosed"
}

/// A setting changed as the user changes one in Settings, and the words History records it in
/// (`SettingsActions.change(_:)`).
public enum TestSettingChange {
    public static let make: @Sendable (inout AppSettings) -> Void = { $0.renameFiles = false }
    public static let summary = "Changed renameFiles to false"
}
