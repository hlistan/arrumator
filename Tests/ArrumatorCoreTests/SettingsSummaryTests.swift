@testable import ArrumatorCore
import Foundation
import Testing

/// How History words a change of settings: each setting by the name Settings shows it under, with its value in words
/// (the QA run of 15 October 2026, C10-1, C11-3).
@Suite struct SettingsSummaryTests {
    @Test func aSettingIsNamedAsSettingsShowsIt() throws {
        let settings = try AppSettings.bundledDefaults()
        #expect(try SettingsActions.summary(["groupLabelsByKind": .bool(true)], in: settings) == "Group labels by kind: on",
                "History says what the person saw in Settings, never the key the file stores it under")
    }

    @Test func pausingIsSaidAsFilingPaused() {
        #expect(SettingsActions.pausedSummary == "Filing paused", "the sidebar says Pause filing, so History says filing paused")
        #expect(SettingsActions.resumedSummary == "Filing resumed", "and resumed")
    }

    @Test func everySettingHasANameOfItsOwn() {
        let names = AppSettings.CodingKeys.allCases.map(\.historyName)
        #expect(names.allSatisfy { !$0.trimmingCharacters(in: .whitespaces).isEmpty }, "each has a name: \(names)")
        #expect(Set(names).count == names.count, "and no two share one, or History could not tell them apart: \(names)")
        #expect(AppSettings.CodingKeys.notifyOnReview.historyName == "Notifications › When a document needs you",
                "a setting under a group is named under it, as Settings shows it")
    }

    @Test func aBooleanReadsOnOrOff() throws {
        let settings = try AppSettings.bundledDefaults()
        #expect(try SettingsActions.summary(["renameFiles": .bool(false), "transliterate": .bool(true)], in: settings)
                == "Rename files: off; Transliterate names to Latin letters: on", "on and off, in the order of the keys")
    }

    @Test func theProfileComesFirstThenTheOtherSettings() throws {
        var settings = try AppSettings.bundledDefaults()
        let smart = try #require(settings.modelProfiles.values.first { $0.name == "Smart" })
        settings.profile = try #require(settings.modelProfiles.first { $0.value == smart }?.key)
        #expect(try SettingsActions.summary(["profile": .string(settings.profile), "renameFiles": .bool(false)], in: settings)
                == "Reading with the profile “Smart”; Rename files: off", "the profile sentence keeps its form and comes first")
        #expect(try SettingsActions.summary(["profile": .string(settings.profile)], in: settings) == "Reading with the profile “Smart”",
                "alone, it is the whole summary")
    }

    @Test func aSettingTakenAwayReadsNoneAndAWholeObjectReadsChanged() throws {
        let settings = try AppSettings.bundledDefaults()
        #expect(try SettingsActions.summary(["ollamaBinaryPath": .null, "modelProfiles": .object([:]), "traceRawRetentionDays": .number(30)],
                                            in: settings)
                == "Model profiles: changed; Ollama program: none; Keep full model prompts: 30",
                "none for one taken away, the number as written, and a whole object only as changed")
    }

    @Test func aKeyThisVersionDoesNotKnowIsNamedByItself() throws {
        #expect(try SettingsActions.summary(["futureSetting": .bool(true)], in: try AppSettings.bundledDefaults()) == "futureSetting: on",
                "a key an earlier or later version wrote is still said, by its key")
    }
}
