import ArrumatorCore
import Foundation

extension ArrumatorRuntime {
    /// What the app does every `maintenance.interval`: prunes logs, trims traces, writes stale record files, and looks
    /// for what another process left in hand when it ended, which no commit announced (`followOtherProcesses()`).
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
        // Work another process queued wakes the queues as it commits (`followOtherProcesses()`); what one left in hand
        // when it ended, as a command killed part way does, announced nothing, and is put back into the queue now.
        await coordinator.wake()
        await taskQueue.wake()
        await conversationQueue.wake()
    }

    /// Follows what other processes commit to the index, as `arrumatorcli` beside the app (`AppDatabase.othersCommits()`):
    /// each change has every observation of the index look again, so the app's pages and the sidebar's counts follow it,
    /// and wakes the three queues and the judge of labels that look alike, which take up a document, a task, a question
    /// or a pair of labels another process made at once rather than at their next look. It runs from the start, while the
    /// work waits for the archive or its rebuild too, until the runtime stops; a worker not started yet is woken for
    /// nothing.
    func followOtherProcesses() async {
        let changes = database.othersCommits()
        await tasks.run("other-processes") { [coordinator, taskQueue, conversationQueue, labelJudge] in
            for await _ in changes {
                await coordinator.wake()
                await taskQueue.wake()
                await conversationQueue.wake()
                labelJudge.wake()
            }
        }
    }
}
