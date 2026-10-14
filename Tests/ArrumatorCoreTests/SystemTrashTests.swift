@testable import ArrumatorCore
import Foundation
import Synchronization
import Testing

/// The Trash the app runs on (`SystemTrash`) is asked which Trash a volume has, never made or written to (§4.3); the system's
/// answer is replaced by a folder of the scratch root, so no test reads the Trash of the machine it runs on.
@Suite struct SystemTrashTests {
    /// An item that is not there yet is told by the nearest folder that is.
    @Test func theTrashOfAVolumeIsToldForAnItemNotThereYetAndHoldsOnlyWhatIsInIt() throws {
        let env = try TestEnvironmentSync.make()
        defer { env.cleanup() }
        let volumeTrash = env.root.appendingPathComponent("Trash", isDirectory: true)
        try FileManager.default.createDirectory(at: volumeTrash, withIntermediateDirectories: true)
        let asked = Mutex<URL?>(nil)
        let trash = SystemTrash(trashOfVolume: { folder in asked.withLock { $0 = folder }; return volumeTrash })
        let notThere = volumeTrash.appendingPathComponent("not there/a file.pdf")
        #expect(trash.holds(notThere), "it holds a file below it, though it is not there")
        let askedOf = asked.withLock { $0 }
        #expect(askedOf?.standardizedFileURL == volumeTrash.standardizedFileURL, "asked of the nearest folder that is there")
        #expect(!trash.holds(env.root.appendingPathComponent("a file.pdf")) && !trash.holds(env.root.appendingPathComponent("Archive/a file.pdf")),
                "and not one beside it, nor in the archive")
    }

    @Test func aPathThatGetsOutOfTheTrashByDotDotThroughAFolderNotThereIsNotHeldAndEndsTheWalk() throws {
        let env = try TestEnvironmentSync.make()
        defer { env.cleanup() }
        let volumeTrash = env.root.appendingPathComponent("Trash", isDirectory: true)
        try FileManager.default.createDirectory(at: volumeTrash, withIntermediateDirectories: true)
        let trash = SystemTrash(trashOfVolume: { _ in volumeTrash })
        // A folder that is not there, then .., never shortened a walk that cut the last component of the path as written.
        #expect(!trash.holds(volumeTrash.appendingPathComponent("nope/../../Documents/a file.pdf")), "out of the Trash by ..")
        #expect(trash.holds(volumeTrash.appendingPathComponent("nope/../still there/a file.pdf")), "and one that stays in it is held")
        #expect(SystemTrash.nearestFolder(above: env.root.appendingPathComponent("nope/../../x.txt")).standardizedFileURL
                    == env.root.deletingLastPathComponent().standardizedFileURL, "the walk goes up from where the .. leads")
        #expect(SystemTrash.nearestFolder(above: URL(fileURLWithPath: "/arrumator-nothing-here/a/../b/c.txt")).path == "/", "to the top at most")
        #expect(SystemTrash.nearestFolder(above: URL(fileURLWithPath: "/arrumator-nothing-here/a/..")).path == "/", "also ending in ..")
        #expect(SystemTrash.nearestFolder(above: URL(fileURLWithPath: "/")).path.hasPrefix("/"), "and from the top itself")
    }
}
