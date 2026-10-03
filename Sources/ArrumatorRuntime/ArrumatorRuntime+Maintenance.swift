import ArrumatorCore
import Foundation

extension ArrumatorRuntime {
    /// What the app does every `maintenance.interval`: prunes logs, trims traces, writes stale record files, and looks
    /// for what another process queued or left.
    func maintain() async {
        let current = await settings.current
        Log.shared.prune(config.logging, now: time.now())
        do {
            let trimmed = try await traces.trimRawPayloads(olderThanDays: current.traceRawRetentionDays)
            if trimmed > 0 { Log.info(.app, "Trimmed raw model payloads", ["steps": String(trimmed)]) }
        } catch {
            Log.error(.app, "Maintenance failed", ["error": error.localizedDescription])
        }
        do { try await records.flush() } catch {
            Log.error(.db, "Could not write record files", ["error": error.localizedDescription])
        }
        // Jobs another process queued, such as `arrumatorcli review retry`, wake no worker here; this does. So are tasks
        // and questions another process asked, or left in hand when it ended, as a command killed part way does.
        await coordinator.wake()
        await taskQueue.wake()
        await conversationQueue.wake()
    }
}
