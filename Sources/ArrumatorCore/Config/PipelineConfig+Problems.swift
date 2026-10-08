import Foundation

extension PipelineConfig {
    /// The limits of the sections the rest of `problems` does not check: no value the code that reads it would trap on,
    /// such as a negative count given to `prefix`, would spin on, as an interval of 0 between rounds, or would turn off
    /// without a word, as a count of 0 that lists nothing; and no name of the archive's record files that is not one name
    /// of its own the watchers skip.
    var limitProblems: [String] {
        watcher.problems + records.problems(managedBy: watcher) + ingest.problems + entities.limitProblems + analysisProblems
            + labels.problems + naming.problems + search.problems + logging.problems + power.problems + stats.problems
            + interface.problems + database.problems
            + Limits.moreThanZero("maintenance", ["interval": maintenance.interval]) + settingsLock.problems
    }

    /// An excerpt of a document holds its head beside its tail, as it is read and as a question about it is answered.
    private var analysisProblems: [String] {
        var problems = Limits.atLeastOne("analysis", ["embeddingSummaryChars": analysis.embeddingSummaryChars,
                                                      "embeddingNumCtx": analysis.embeddingNumCtx, "numCtx": analysis.numCtx,
                                                      "llmOptions.numPredict": analysis.llmOptions.numPredict,
                                                      "vlmNumPredict": analysis.vlmNumPredict])
        problems += Limits.notNegative("analysis", ["embeddingIdentifiersLimit": analysis.embeddingIdentifiersLimit,
                                                    "promptDatesLimit": analysis.promptDatesLimit,
                                                    "promptIdentifiersLimit": analysis.promptIdentifiersLimit], zero: "shows none")
        for (key, numPredict) in [("llmOptions.numPredict", analysis.llmOptions.numPredict), ("vlmNumPredict", analysis.vlmNumPredict)]
            where numPredict >= analysis.numCtx {
            problems.append("analysis.\(key) leaves no room in analysis.numCtx")
        }
        if analysis.titleGroundedShare <= 0 || analysis.titleGroundedShare > 1 {
            problems.append("analysis.titleGroundedShare must be more than 0 and at most 1")
        }
        problems += Limits.atLeastOne("analysis", ["partiesWithoutSender": analysis.partiesWithoutSender])
        if analysis.excerptTailDivisor >= 2 {
            for (key, chars) in [("analysis.excerptChars", analysis.excerptChars), ("conversation.documentChars", conversation.documentChars)]
                where !ExtractedContent.excerptHasHead(maxChars: chars, tailDivisor: analysis.excerptTailDivisor) {
                problems.append("\(key) leaves no room for the start of a text beside its end")
            }
        }
        return problems
    }
}

/// How a limit's refusal reads, one per key: `section.key must be at least 1`, `… cannot be negative`, `… must be more
/// than 0`.
enum Limits {
    static func atLeastOne(_ section: String, _ values: KeyValuePairs<String, Int>) -> [String] {
        values.filter { $0.value < 1 }.map { "\(section).\($0.key) must be at least 1" }
    }

    /// `zero` says what 0 does, which is allowed.
    static func notNegative(_ section: String, _ values: KeyValuePairs<String, Int>, zero: String) -> [String] {
        values.filter { $0.value < 0 }.map { "\(section).\($0.key) cannot be negative: 0 \(zero)" }
    }

    static func moreThanZero(_ section: String, _ values: KeyValuePairs<String, Double>) -> [String] {
        values.filter { $0.value <= 0 }.map { "\(section).\($0.key) must be more than 0" }
    }
}

extension WatcherConfig {
    /// A file is taken once it stopped changing, polled at an interval and over polls that are not none, and said to be
    /// taking long only after it could have stopped; the app's own changes are expected for longer than FSEvents takes to
    /// report them; the archive's own files are told by a prefix and an extension that name something; and an archive
    /// away is looked for at an interval.
    var problems: [String] {
        var problems = Limits.moreThanZero("watcher", ["stabilityPollInterval": stabilityPollInterval, "awayPollSeconds": awayPollSeconds])
        problems += Limits.atLeastOne("watcher", ["stabilityRequiredPolls": stabilityRequiredPolls, "maxPackageItems": maxPackageItems])
        if unopenableWaitSeconds < 0 { problems.append("watcher.unopenableWaitSeconds cannot be negative") }
        if stabilityMaxWaitSeconds <= max(zeroByteWaitSeconds, stabilityPollInterval * Double(stabilityRequiredPolls)) {
            problems.append("watcher.stabilityMaxWaitSeconds must be more than watcher.zeroByteWaitSeconds and than "
                + "watcher.stabilityPollInterval times watcher.stabilityRequiredPolls, so a file is said to be taking long only after it could have stopped")
        }
        if fsEventsLatency < 0 { problems.append("watcher.fsEventsLatency cannot be negative") }
        if zeroByteWaitSeconds < 0 { problems.append("watcher.zeroByteWaitSeconds cannot be negative") }
        if selfChangeTTLSeconds <= fsEventsLatency {
            problems.append("watcher.selfChangeTTLSeconds must be more than watcher.fsEventsLatency, so the app's own changes are expected when their events come")
        }
        if managedFilePrefix.isEmpty || managedFilePrefix.contains("/") {
            problems.append("watcher.managedFilePrefix must be one character or more, without /")
        }
        if managedFileExtension.isEmpty || managedFileExtension.contains(where: { $0 == "/" || $0 == "." })
            || managedFileExtension != managedFileExtension.lowercased() {
            problems.append("watcher.managedFileExtension must be written in lowercase, without a dot or /, as a file's extension is compared")
        }
        if !sidecarSuffix.hasPrefix(".") || sidecarSuffix.contains("/") || sidecarSuffix.lowercased() == "." + managedFileExtension
            || sidecarSuffix.count < 2 {
            problems.append("watcher.sidecarSuffix must begin with a dot, hold no / and be more than the extension of the archive's own files, "
                + "or every such file would be taken for a sidecar")
        }
        return problems
    }
}

extension RecordsConfig {
    /// Every name is one name, not a path, and no two are the same, whatever their case; a record file is named as the
    /// watchers know the archive's own files, so it is never taken for a document.
    func problems(managedBy watcher: WatcherConfig) -> [String] {
        let names = [("documentsFileName", documentsFileName), ("systemFolderName", systemFolderName),
                     ("historyFolderName", historyFolderName), ("labelRulesFileName", labelRulesFileName),
                     ("searchTasksFileName", searchTasksFileName), ("conversationsFolderName", conversationsFolderName)]
        var problems = names.filter { !Self.isOneName($0.1) }.map { "records.\($0.0) “\($0.1)” must be one name, not a path" }
        var seen: [String: String] = [:]
        for (key, name) in names {
            if let other = seen[name.lowercased()] {
                problems.append("records.\(key) and records.\(other) are one name, “\(name)”")
            } else {
                seen[name.lowercased()] = key
            }
        }
        for (key, name) in [("documentsFileName", documentsFileName), ("labelRulesFileName", labelRulesFileName),
                            ("searchTasksFileName", searchTasksFileName)]
            where !name.hasPrefix(watcher.managedFilePrefix) || !name.lowercased().hasSuffix("." + watcher.managedFileExtension) {
            problems.append("records.\(key) “\(name)” must begin with watcher.managedFilePrefix and end in .\(watcher.managedFileExtension), "
                + "or it would be taken for a document")
        }
        if setAsideSuffix.isEmpty || setAsideSuffix.contains("/") {
            problems.append("records.setAsideSuffix must be one character or more, without /")
        }
        if !(stagedLeftoverMinutes > 0) || !stagedLeftoverMinutes.isFinite {
            problems.append("records.stagedLeftoverMinutes must be more than 0")
        }
        return problems
    }

    private static func isOneName(_ name: String) -> Bool { !name.isEmpty && name != "." && name != ".." && !name.contains("/") }
}

extension IngestConfig {
    /// A job waits before it is tried again, and quitting gives the work in hand time to stop.
    var problems: [String] {
        var problems = Limits.moreThanZero("ingest", ["quitTimeout": quitTimeout])
        if retryDelays.all.contains(where: { $0 <= 0 }) {
            problems.append("ingest.retryDelays must each be more than 0, so a job that waits does not ask again at once")
        }
        return problems
    }
}

extension EntityConfig {
    /// A date is looked for beside its label, among plausible years, and a line is crowded with more than one date.
    var limitProblems: [String] {
        var problems = Limits.atLeastOne("entities", ["labelWindowChars": labelWindowChars])
        problems += Limits.notNegative("entities", ["yearsBack": yearsBack, "yearsForward": yearsForward], zero: "is this year alone")
        if crowdedLineDates < 2 { problems.append("entities.crowdedLineDates must be at least 2: a line with one date is not crowded") }
        return problems
    }
}

extension LabelsConfig {
    /// A label holds a character at least, a word grounds a name or title from two letters, and a likeness is a share of
    /// 0 to 1 that some labels fall below.
    var problems: [String] {
        var problems = Limits.atLeastOne("labels", ["maxValueChars": maxValueChars, "objectIdentifierDigits": objectIdentifierDigits])
        if groundingLetters < 2 { problems.append("labels.groundingLetters must be at least 2: a word of one letter says nothing on its own") }
        problems += Limits.atLeastOne("labels.vocabulary", ["suggestionLimit": vocabulary.suggestionLimit])
        problems += Limits.notNegative("labels.vocabulary", ["promptPreferred": vocabulary.promptPreferred,
                                                             "promptUnwanted": vocabulary.promptUnwanted,
                                                             "judgeDocuments": vocabulary.judgeDocuments], zero: "shows none")
        for (kind, policy) in vocabulary.kinds.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
            let key = "labels.vocabulary.kinds.\(kind.rawValue)"
            for (name, similarity) in [("mergeSimilarity", policy.mergeSimilarity), ("suggestSimilarity", policy.suggestSimilarity)]
                where similarity <= 0 || similarity > 1 {
                problems.append("\(key).\(name) must be more than 0 and at most 1")
            }
            if policy.promptLimit < 0 { problems.append("\(key).promptLimit cannot be negative: 0 shows none") }
        }
        return problems
    }
}

extension NamingConfig {
    /// A name holds a character at least, and a name taken is told apart by a number in it, `%d`, and nothing else
    /// `String(format:)` would read. A reading's name is made of its title and, at most once each, its date and its
    /// sender, each but the last followed by a separator that cleaning keeps (`FilenameBuilder.sanitize`).
    var problems: [String] {
        var problems = Limits.atLeastOne("naming", ["maxChars": maxChars, "maxBytes": maxBytes])
        if collisionFormat.components(separatedBy: "%").count != 2 || !collisionFormat.contains("%d") || collisionFormat.contains("/") {
            problems.append("naming.collisionFormat must hold %d once, no other %, and no /")
        }
        if parts.filter({ $0 == .title }).count != 1 || Set(parts).count != parts.count {
            problems.append("naming.parts must list the title once, and the date and the sender at most once each")
        }
        if separators.count != max(parts.count - 1, 0) {
            problems.append("naming.separators must give one separator for each part of naming.parts but the last")
        }
        let unnamed = ["/"] + forbiddenCharacters
        if separators.contains(where: { $0.isEmpty || unnamed.contains(where: $0.contains) }) {
            problems.append("naming.separators must each hold a character, and no / nor any of naming.forbiddenCharacters")
        }
        return problems
    }
}

extension SearchConfig {
    /// A search finds and lists something, ranks by a positive constant, and finds by meaning above a likeness of 0 to 1.
    var problems: [String] {
        var problems = Limits.moreThanZero("search", ["rrfK": rrfK])
        problems += Limits.atLeastOne("search", ["ftsCandidateLimit": ftsCandidateLimit, "resultLimit": resultLimit, "snippetTokens": snippetTokens])
        if semanticMinSimilarity <= 0 || semanticMinSimilarity > 1 {
            problems.append("search.semanticMinSimilarity must be more than 0 and at most 1")
        }
        return problems
    }
}

extension LoggingConfig {
    /// Logs are kept a day at least, in some bytes, and followed with a pause.
    var problems: [String] {
        Limits.atLeastOne("logging", ["keepDays": keepDays, "bufferLimit": bufferLimit])
            + (maxBytes < 1 ? ["logging.maxBytes must be at least 1"] : [])
            + Limits.moreThanZero("logging", ["followInterval": followInterval])
    }
}

extension PowerConfig {
    /// The battery left is a percentage.
    var problems: [String] {
        (1...100).contains(pauseBelowBatteryPercent) ? [] : ["power.pauseBelowBatteryPercent must be from 1 to 100"]
    }
}

extension StatsConfig {
    var problems: [String] {
        (windowsDays.all.contains { $0 < 1 } ? ["stats.windowsDays must each be at least 1"] : [])
            + Limits.atLeastOne("stats", ["diagnosticsTraceLimit": diagnosticsTraceLimit])
    }
}

extension InterfaceConfig {
    /// The longest the interface waits, in seconds: a day, which no wait for macOS comes near, and which keeps a value read
    /// from JSON within what a `Duration` holds.
    static let longestWait: Double = 86_400

    /// A list shows something; a preview may show nothing; macOS is given a while to answer, and no more than a day.
    var problems: [String] {
        Limits.atLeastOne("interface", ["recentlyProcessed": recentlyProcessed, "pageSize": pageSize,
                                        "sidebarLabelsPerKind": sidebarLabelsPerKind, "sidebarLabels": sidebarLabels,
                                        "menuBarRecent": menuBarRecent, "notificationEvents": notificationEvents])
            + Limits.notNegative("interface", ["extractPreviewChars": extractPreviewChars], zero: "prints none")
            + Limits.moreThanZero("interface", ["notificationAskTimeout": notificationAskTimeout])
            + (menuBarSettleSeconds < 0 ? ["interface.menuBarSettleSeconds cannot be negative: 0 says it at once"] : [])
            + [("notificationAskTimeout", notificationAskTimeout), ("menuBarSettleSeconds", menuBarSettleSeconds)]
            .filter { $0.1 > Self.longestWait }.map { "interface.\($0.0) must be at most \(Int(Self.longestWait)) seconds" }
    }
}

extension SettingsLockConfig {
    /// A change waits a while for another process's, asking again more often than that.
    var problems: [String] {
        var problems = Limits.moreThanZero("settingsLock", ["timeout": timeout, "pollInterval": pollInterval])
        if pollInterval >= timeout { problems.append("settingsLock.pollInterval must be less than settingsLock.timeout") }
        return problems
    }
}

extension DatabaseConfig {
    /// SQLite takes how long a write waits for the index in milliseconds, as a 32-bit number
    /// (https://sqlite.org/c3ref/busy_timeout.html): 0 does not wait at all.
    static let busyTimeoutMost = Double(Int32.max) / 1_000

    /// A write waits for another process holding the index, for as long as SQLite can be told.
    var problems: [String] {
        busyTimeout > 0 && busyTimeout <= Self.busyTimeoutMost ? []
            : ["database.busyTimeout must be more than 0 and at most \(Int(Self.busyTimeoutMost)) seconds"]
    }
}

extension TasksConfig {
    /// Every effort has its preset, with counts and times that are not none, and the request's limits are not none.
    var problems: [String] {
        var problems: [String] = []
        for effort in TaskEffort.allCases {
            guard let preset = efforts[effort] else {
                problems.append("tasks.efforts.\(effort.rawValue) is missing")
                continue
            }
            if preset.repairAttempts < 0 { problems.append("tasks.efforts.\(effort.rawValue).repairAttempts cannot be negative") }
            if preset.numPredict < 1 { problems.append("tasks.efforts.\(effort.rawValue).numPredict must be at least 1") }
            if preset.timeout <= 0 { problems.append("tasks.efforts.\(effort.rawValue).timeout must be more than 0") }
            for kind in preset.promptLabels.keys where kind.isUsersOwn {
                problems.append("tasks.efforts.\(effort.rawValue).promptLabels.\(kind.rawValue): the model is never shown the user's own labels; remove it")
            }
            for (kind, limit) in preset.promptLabels.sorted(by: { $0.key.rawValue < $1.key.rawValue }) where limit < 0 {
                problems.append("tasks.efforts.\(effort.rawValue).promptLabels.\(kind.rawValue) cannot be negative: 0 shows none")
            }
        }
        if maxValuesPerKind < 1 { problems.append("tasks.maxValuesPerKind must be at least 1") }
        if maxWords < 0 { problems.append("tasks.maxWords cannot be negative") }
        if alternativesGap < 0 { problems.append("tasks.alternativesGap cannot be negative") }
        if inflectionLetters < 0 { problems.append("tasks.inflectionLetters cannot be negative") }
        if maxGroupingDepth < 1 { problems.append("tasks.maxGroupingDepth must be at least 1") }
        if defaultGrouping.count > maxGroupingDepth { problems.append("tasks.defaultGrouping is deeper than tasks.maxGroupingDepth") }
        if maxTitleChars < 1 { problems.append("tasks.maxTitleChars must be at least 1") }
        if maxDocuments < 1 { problems.append("tasks.maxDocuments must be at least 1") }
        do { _ = try withoutLabelFolder(.sender) } catch {
            problems.append("tasks.withoutLabelFolder: \(error.localizedDescription)")
        }
        return problems
    }
}
