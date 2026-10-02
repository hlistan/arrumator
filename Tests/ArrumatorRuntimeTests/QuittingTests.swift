import ArrumatorCore
import ArrumatorRuntime
import Foundation
import Testing

/// Quitting stops the app's work before the process ends (`ArrumatorRuntime.stopBeforeQuitting()`), which the app waits
/// for by answering AppKit's `applicationShouldTerminate(_:)` with `.terminateLater`.
@Suite struct QuittingTests {
    @Test func quittingStopsTheRunningAppBeforeItEnds() async throws {
        let home = try await RuntimeHome.make()
        defer { home.cleanup() }
        try await home.withoutOllama()
        let runtime = try await home.open()
        await runtime.start()
        try await runtime.services.history.record(.paused, summary: "Paused just before quitting")
        #expect(await runtime.stopBeforeQuitting(), "an app whose work stops at once stops well within ingest.quitTimeout")
        let history = runtime.services.layout(await runtime.settings.current).history
        // No folder yet is nothing written yet.
        let files = (try? FileManager.default.contentsOfDirectory(at: history, includingPropertiesForKeys: nil)) ?? []
        let written = try files.map { try String(contentsOf: $0, encoding: .utf8) }.joined()
        #expect(written.contains("Paused just before quitting"),
                "everything stopping does is done when it returns: the archive's history holds what happened last")
        let (ingest, tasks) = (await runtime.coordinator.status, await runtime.taskQueue.status)
        #expect(ingest.current == nil && tasks == .idle, "and nothing is in hand")
    }
}
