import ArrumatorCore
import ArrumatorTesting
import Foundation
import Testing

/// The limits of `pipeline.json` the code that reads them relies on: a value it would trap on, spin on or turn off
/// without a word stops the app, naming its key, and the smallest values that work are taken.
@Suite struct PipelineLimitsTests {
    /// Values the code reading them would trap on (a negative count given to `prefix`, a range upside down), spin on (an
    /// interval of 0 between rounds) or turn off without a word (a list of 0 rows, a name that is a path), each with the
    /// key its refusal names.
    static let limitsThePipelineCannotRunWith: [(override: String, key: String)] = [
        (#"{"ollama": {"healthPollSteady": 0}}"#, "ollama.healthPollSteady"), (#"{"ollama": {"startTimeout": 0}}"#, "ollama.startTimeout"),
        (#"{"ollama": {"retryDelays": [2, -1]}}"#, "ollama.retryDelays"), (#"{"ollama": {"maxRestartsPerHour": -1}}"#, "ollama.maxRestartsPerHour"),
        (#"{"watcher": {"stabilityPollInterval": 0}}"#, "watcher.stabilityPollInterval"),
        (#"{"watcher": {"stabilityRequiredPolls": 0}}"#, "watcher.stabilityRequiredPolls"),
        (#"{"watcher": {"selfChangeTTLSeconds": 0.5}}"#, "watcher.selfChangeTTLSeconds"),
        (#"{"watcher": {"managedFilePrefix": ""}}"#, "watcher.managedFilePrefix"),
        (#"{"watcher": {"managedFileExtension": "MD"}}"#, "watcher.managedFileExtension"),
        (#"{"records": {"systemFolderName": ".."}}"#, "records.systemFolderName"),
        (#"{"records": {"documentsFileName": "Lists/_documents.md"}}"#, "records.documentsFileName"),
        (#"{"records": {"searchTasksFileName": "_LABELS.md"}}"#, "records.searchTasksFileName and records.labelRulesFileName"),
        (#"{"records": {"documentsFileName": "documents.md"}}"#, "records.documentsFileName “documents.md” must begin with"),
        (#"{"ingest": {"retryDelays": [0]}}"#, "ingest.retryDelays"), (#"{"ingest": {"quitTimeout": 0}}"#, "ingest.quitTimeout"),
        (#"{"entities": {"labelWindowChars": -1}}"#, "entities.labelWindowChars"), (#"{"entities": {"yearsForward": -2}}"#, "entities.yearsForward"),
        (#"{"analysis": {"excerptChars": 2}}"#, "analysis.excerptChars"), (#"{"conversation": {"documentChars": 2}}"#, "conversation.documentChars"),
        (#"{"analysis": {"promptDatesLimit": -1}}"#, "analysis.promptDatesLimit"),
        (#"{"analysis": {"llmOptions": {"numPredict": 12288}}}"#, "analysis.llmOptions.numPredict"),
        (#"{"labels": {"maxValueChars": 0}}"#, "labels.maxValueChars"),
        (#"{"labels": {"objectIdentifierDigits": 0}}"#, "labels.objectIdentifierDigits"),
        (#"{"analysis": {"partiesWithoutSender": 0}}"#, "analysis.partiesWithoutSender"),
        (#"{"tasks": {"inflectionLetters": -1}}"#, "tasks.inflectionLetters"),
        (#"{"labels": {"vocabulary": {"promptUnwanted": -1}}}"#, "labels.vocabulary.promptUnwanted"),
        (#"{"labels": {"vocabulary": {"kinds": {"sender": {"mergeSimilarity": 0}}}}}"#, "labels.vocabulary.kinds.sender.mergeSimilarity"),
        (#"{"naming": {"maxBytes": 0}}"#, "naming.maxBytes"), (#"{"naming": {"collisionFormat": " (%@)"}}"#, "naming.collisionFormat"),
        (#"{"search": {"resultLimit": -1}}"#, "search.resultLimit"), (#"{"logging": {"bufferLimit": -1}}"#, "logging.bufferLimit"),
        (#"{"logging": {"keepDays": 0}}"#, "logging.keepDays"), (#"{"power": {"pauseBelowBatteryPercent": 0}}"#, "power.pauseBelowBatteryPercent"),
        (#"{"stats": {"diagnosticsTraceLimit": 0}}"#, "stats.diagnosticsTraceLimit"), (#"{"interface": {"pageSize": -1}}"#, "interface.pageSize"),
        (#"{"interface": {"notificationAskTimeout": 0}}"#, "interface.notificationAskTimeout"),
        (#"{"interface": {"menuBarSettleSeconds": -1}}"#, "interface.menuBarSettleSeconds"),
        (#"{"interface": {"notificationAskTimeout": 1e300}}"#, "interface.notificationAskTimeout"),
        (#"{"maintenance": {"interval": 0}}"#, "maintenance.interval"), (#"{"database": {"busyTimeout": 0}}"#, "database.busyTimeout"),
        (#"{"database": {"busyTimeout": 2147484}}"#, "database.busyTimeout"),
        (#"{"tasks": {"efforts": {"low": {"promptLabels": {"sender": -1}}}}}"#, "tasks.efforts.low.promptLabels.sender"),
    ]

    @Test(arguments: limitsThePipelineCannotRunWith)
    func aLimitThePipelineCannotRunWithStopsTheAppNamingItsKey(_ override: String, _ key: String) async throws {
        let env = try await TestEnvironment.make()
        defer { env.cleanup() }
        try Data(override.utf8).write(to: env.paths.pipelineOverrideURL)
        #expect("\(override) would trap, spin or silence a part of the app, so it stops the app naming \(key)") {
            try PipelineConfig.load(paths: env.paths, environment: TestEnvironment.isolated)
        } throws: { error in
            guard let refused = ConfigRefusal(error) else { return false }
            return refused.name == "pipeline" && refused.underlying.contains(key) && refused.paths == [env.paths.pipelineOverrideURL.path]
                && error.localizedDescription.contains(env.paths.pipelineOverrideURL.path)
        }
    }

    @Test func theSmallestLimitsThatWorkAreTaken() async throws {
        let env = try await TestEnvironment.make()
        defer { env.cleanup() }
        try Data(#"""
            {"analysis": {"excerptChars": 3, "promptDatesLimit": 0}, "watcher": {"stabilityRequiredPolls": 1},
             "ollama": {"maxRestartsPerHour": 0}, "database": {"busyTimeout": 2147483}, "interface": {"extractPreviewChars": 0},
             "tasks": {"efforts": {"low": {"promptLabels": {"sender": 0}}}}}
            """#.utf8).write(to: env.paths.pipelineOverrideURL)
        let config = try PipelineConfig.load(paths: env.paths, environment: TestEnvironment.isolated)
        #expect(config.analysis.excerptChars == 3 && config.tasks.efforts[.low]?.promptLabels[.sender] == 0,
                "an excerpt with room for the separator alone, and 0 where 0 shows none, are values the app can run with")
    }
}
