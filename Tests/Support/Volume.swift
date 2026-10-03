import Foundation

/// The volume the tests' temporary folders are on, for a test whose expectation holds only on some volumes: such a test
/// is enabled only where the volume is as it needs (AGENTS.md §3, Determinism), never left to pass or fail by the Mac.
public enum Volume {
    /// Whether it ignores case, as APFS does unless formatted otherwise, so that `bill.txt` finds `Bill.txt`.
    public static let ignoresCase: Bool = {
        let probe = FileManager.default.temporaryDirectory.appendingPathComponent("arrumator-case-\(UUID().uuidString.lowercased())")
        guard FileManager.default.createFile(atPath: probe.path, contents: nil) else { return false }
        defer { try? FileManager.default.removeItem(at: probe) }
        return FileManager.default.fileExists(atPath: probe.deletingLastPathComponent().appendingPathComponent(probe.lastPathComponent.uppercased()).path)
    }()
}
