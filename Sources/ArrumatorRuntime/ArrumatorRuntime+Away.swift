import ArrumatorCore
import Foundation

extension ArrumatorRuntime {
    /// While the archive's folder is not there, as on a disk not connected, the archive is away (`RuntimeWork.away`):
    /// nothing is read from it, filed into it or written into its record files, and Incoming waits. It is looked for every
    /// `watcher.awayPollSeconds`, and at once when a start is asked for again, as the user presses Try Again
    /// (`archiveLook`); once it is there the start goes on by itself, and reopening the app is never needed. A start
    /// asked for meanwhile waits with this one, rather than failing. A stop meanwhile ends the wait (`CancellationError`).
    /// Another folder put at its path is the watcher's to take (`ArchiveWatcher`), as the archive.
    func waitForArchive() async throws {
        guard !records.archiveIsThere else { return }
        Log.warning(.app, "The archive's folder is not there; waiting until it is back", ["archive": archive.path])
        await setAway(true)
        while !records.archiveIsThere {
            await archiveLook.wait(timeout: config.watcher.awayPollSeconds, time: time)
            try Task.checkCancellation()
        }
        await setAway(false)
        Log.info(.app, "The archive's folder is back", ["archive": archive.path])
    }

    /// The archive's folder going while the work runs, as a disk taken out, is the archive away, as at launch, and its
    /// coming back the work going on (`ArchiveWatcher.presence()`).
    func followArchive(_ presence: AsyncStream<Bool>) async {
        await tasks.run("archive-presence") { [weak self] in
            for await there in presence { await self?.setAway(!there) }
        }
    }

    /// The archive away, or back: the work says so (`RuntimeWork.away`), and the ingest worker pauses, as for the Mac's
    /// power, so Incoming waits: no file of it is read or sent to the model until the archive is back.
    func setAway(_ isAway: Bool) async {
        await coordinator.archive(isAway: isAway)
        await tasks.away(isAway)
    }
}
