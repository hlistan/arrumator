import Darwin
import Testing

/// What a test that needs a file or a folder closed to the user cannot have as the superuser, whom no permissions keep
/// out: it is skipped then, saying why, rather than failing or passing by chance (AGENTS.md §3, determinism).
extension Trait where Self == ConditionTrait {
    /// Only for a user other than the superuser: a test that needs a file nobody may read or write.
    public static var fileModesKeepOut: Self {
        .enabled(if: getuid() != 0, "the superuser reads and writes a file whatever its permissions, so none is closed to it")
    }

    /// Only for a user other than the superuser: a test that needs a folder nobody may list or write into.
    public static var folderModesKeepOut: Self {
        .enabled(if: getuid() != 0, "the superuser lists and writes into a folder whatever its permissions, so none is closed to it")
    }
}
