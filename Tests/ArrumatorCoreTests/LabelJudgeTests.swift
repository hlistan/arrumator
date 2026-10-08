@testable import ArrumatorCore
import ArrumatorTesting
import Foundation
import GRDB
import Synchronization
import Testing

/// Labels that look alike are judged by the model, not the user (docs/how-it-works.md#keeping-labels-one-vocabulary):
/// the same, they are merged into the one more documents have; different, they are kept apart; either recorded as the
/// system's, with its trace, decided where it acts, and never asked again.
@Suite struct LabelJudgeTests {
    static func label(_ kind: LabelKind, _ value: String) -> DocumentLabel { DocumentLabel(kind: kind, value: value) }

    /// A judge that answers as `answers` says, and records each pair it was asked and what it was shown. With `during`, it
    /// acts as the user while it judges, from a task of its own, as the app would.
    final class StubJudging: LabelPairJudging {
        let answers: @Sendable (LabelSuggestion) throws -> LabelVerdict
        let during: (@Sendable () async throws -> Void)?
        let asked = Mutex<[(pair: LabelSuggestion, use: LabelPairUse)]>([])

        init(during: (@Sendable () async throws -> Void)? = nil, _ answers: @escaping @Sendable (LabelSuggestion) throws -> LabelVerdict) {
            self.answers = answers
            self.during = during
        }

        convenience init(_ judgement: LabelJudgement?) {
            self.init { _ in LabelVerdict(judgement: judgement, reason: judgement.map { "They are \($0.rawValue)." }, model: "stub",
                                          problem: judgement == nil ? "no valid answer" : nil) }
        }

        func judge(_ pair: LabelSuggestion, use: LabelPairUse, profile: ModelProfile, config: PipelineConfig,
                   trace: TraceContext) async throws -> LabelVerdict {
            asked.withLock { $0.append((pair, use)) }
            if let during { try await Task { try await during() }.value }
            await trace.record(.judge, startedAt: Date(), input: pair)
            return try answers(pair)
        }

        var pairs: [LabelSuggestion] { asked.withLock { $0.map(\.pair) } }
    }

    /// An archive of three bills from EDP, one with the sender misspelt, and two letters to people whose names are a
    /// letter apart: two pairs that look alike, the senders' the more alike.
    static func archive() async throws -> Harness {
        let edp = [label(.sender, "EDP Comercial")]
        let h = try await Harness.make(analyzer: PerFileAnalyzer(labels: [
            "july.txt": edp, "august.txt": edp, "september.txt": [label(.sender, "EDP Comercail")],
            "maria.txt": [label(.party, "Maria Silva")], "mario.txt": [label(.party, "Mario Silva")],
        ]))
        for name in ["july.txt", "august.txt", "september.txt", "maria.txt", "mario.txt"] { try await h.ingest(name, text: "A letter: \(name)") }
        return h
    }

    static func judge(_ h: Harness, _ judging: StubJudging) -> LabelJudge { LabelJudge(services: h.services, judging: judging) }

    private func trace(_ h: Harness, _ id: Int64?) async throws -> TraceRecord {
        try #require(try await h.env.database.reader.read { db in try TraceRecord.fetchOne(db, key: id) })
    }

    // MARK: What a judgement does

    @Test func labelsJudgedTheSameAreMergedIntoTheOneMoreDocumentsHaveAsTheSystemsDecision() async throws {
        let h = try await Self.archive()
        defer { h.env.cleanup() }
        let judging = StubJudging(.same)
        let judge = Self.judge(h, judging)
        #expect(await judge.judgeNext() == .judged, "the first pair is judged")
        #expect(judging.pairs.map(\.value) == ["EDP Comercail"], "the most alike first: the misspelt sender")
        let documents = try await h.services.documents.list(DocumentFilter(), limit: 10)
        #expect(documents.filter { $0.labels(.sender) == ["EDP Comercial"] }.count == 3, "all three bills are from EDP Comercial now")
        #expect(try await h.services.labels.rules().map(\.summary) == ["sender “EDP Comercail” → “EDP Comercial”"],
                "a rule, merged into the label two documents have, which readings follow and the user can forget")
        let event = try #require(try await h.services.history.events(limit: 5, kinds: [.labelsMerged]).first)
        #expect(event.actor == .system && event.summary == "Merged sender “EDP Comercail” into “EDP Comercial” on 1 document, which the model judged the same",
                "History says the system merged them, as the model judged")
        let trace = try await trace(h, event.traceId)
        #expect(trace.source == TraceSource.labels.rawValue && trace.outcome == LabelJudgement.same.rawValue && trace.docId == nil,
                "and links the judgement's trace, which says what came of it")
    }

    @Test func labelsJudgedDifferentAreKeptApartAndNeverJudgedAgain() async throws {
        let h = try await Self.archive()
        defer { h.env.cleanup() }
        let judging = StubJudging(.different)
        let judge = Self.judge(h, judging)
        let (first, second) = (await judge.judgeNext(), await judge.judgeNext())
        #expect(first == .judged && second == .judged, "both pairs are judged")
        #expect(await judge.judgeNext() == .idle(nil), "and then there is nothing to judge: it waits for a change")
        #expect(judging.pairs.map(\.value) == ["EDP Comercail", "Mario Silva"], "each pair asked once")
        #expect(try await h.services.labels.rules().map(\.action) == [.keepApart, .keepApart], "each kept apart, as a rule")
        let events = try await h.services.history.events(limit: 5, kinds: [.labelsKeptApart])
        #expect(events.allSatisfy { $0.actor == .system && $0.summary.hasSuffix(", which the model judged different") && $0.traceId != nil },
                "History says the system kept them apart, as the model judged: \(events.map(\.summary))")
        #expect(try await h.services.labels.suggestions().isEmpty, "and no pair looks alike any more")
    }

    @Test func theModelIsShownWhatEachLabelIsUsedForTheNewestDocumentsFirst() async throws {
        let h = try await Self.archive()
        defer { h.env.cleanup() }
        let judging = StubJudging(.different)
        _ = await Self.judge(h, judging).judgeNext()
        let use = try #require(judging.asked.withLock { $0.first?.use })
        #expect(use == LabelPairUse(valueDocuments: 1, valueNames: ["september.txt"], intoDocuments: 2, intoNames: ["august.txt", "july.txt"]),
                "how many documents have each, and their names, the newest first: \(use)")
        var fewer = h.services
        fewer.config.labels.vocabulary.judgeDocuments = 1
        let shown = try await fewer.labels.use(of: try #require(judging.pairs.first), names: fewer.config.labels.vocabulary.judgeDocuments)
        #expect(shown.intoNames == ["august.txt"] && shown.intoDocuments == 2, "at most labels.vocabulary.judgeDocuments names, all counted")
        let none = try await fewer.labels.use(of: try #require(judging.pairs.first), names: 0)
        #expect(none.valueNames.isEmpty && none.intoNames.isEmpty && none.valueDocuments == 1, "0 shows no name")
    }

    // MARK: Decided where it acts

    @Test func whatTheUserDecidedWhileTheModelJudgedStands() async throws {
        let h = try await Self.archive()
        defer { h.env.cleanup() }
        let judging = StubJudging(during: { try await h.labels.keepApart(Self.label(.sender, "EDP Comercail"), from: "EDP Comercial") }) { _ in
            LabelVerdict(judgement: .same, reason: "A typo.", model: "stub", problem: nil)
        }
        let judge = Self.judge(h, judging)
        #expect(await judge.judgeNext() == .judged, "the pair is judged")
        let rules = try await h.services.labels.rules()
        #expect(rules.map(\.action) == [.keepApart] && rules.first?.createdAt != nil, "the user kept them apart meanwhile, and that stands")
        let merged = try await h.services.history.events(limit: 5, kinds: [.labelsMerged])
        #expect(merged.isEmpty, "nothing is merged")
        let trace = try #require(try await h.env.database.reader.read { db in
            try TraceRecord.filter(Column("source") == TraceSource.labels.rawValue).fetchOne(db)
        })
        #expect(trace.outcome == LabelJudge.decidedMeanwhileOutcome, "and the trace says it was decided meanwhile")
    }

    @Test func aJudgementIsActedOnOnlyWhileBothLabelsAreInUseAndNoRuleDecidesEither() async throws {
        let pair = LabelSuggestion(kind: .sender, value: "EDP Comercail", into: "EDP Comercial", similarity: 0.97, reason: .writtenAlike)
        // Each condition alone leaves the judgement unacted on.
        let meanwhile: [(String, @Sendable (Harness) async throws -> Void)] = [
            ("one label no longer on any document", { h in _ = try await h.labels.remove(Self.label(.sender, "EDP Comercail")) }),
            ("the other no longer on any document", { h in _ = try await h.labels.remove(Self.label(.sender, "EDP Comercial")) }),
            ("the two kept apart", { h in _ = try await h.labels.keepApart(Self.label(.sender, "EDP Comercial"), from: "EDP Comercail") }),
            ("a rule about the one", { h in
                try await h.env.database.writer.write { db in
                    var rule = LabelRule(kind: .sender, value: "EDP Comercail", action: .ignore, target: nil, createdAt: h.env.time.now())
                    try rule.insert(db)
                }
            }),
            ("a rule about the other", { h in
                try await h.env.database.writer.write { db in
                    var rule = LabelRule(kind: .sender, value: "EDP Comercial", action: .merge, target: "EDP", createdAt: h.env.time.now())
                    try rule.insert(db)
                }
            }),
        ]
        for (what, change) in meanwhile {
            let h = try await Self.archive()
            defer { h.env.cleanup() }
            try await change(h)
            let rules = try await h.services.labels.rules()
            let acted = try await h.labels.decide(pair, .same, trace: nil)
            #expect(acted == nil, "\(what): nothing is done")
            #expect(try await h.services.labels.rules() == rules, "\(what): and no rule is made")
        }
        let h = try await Self.archive()
        defer { h.env.cleanup() }
        let acted = try await h.labels.decide(pair, .same, trace: nil)
        #expect(acted?.documents.count == 1, "with neither, the judgement is acted on")
    }

    @Test func labelsAsManyDocumentsHaveAreMergedIntoTheSuggestionsOwn() async throws {
        let h = try await Harness.make(analyzer: PerFileAnalyzer(labels: [
            "a.txt": [Self.label(.sender, "EDP Comercial")], "b.txt": [Self.label(.sender, "EDP Comercail")],
        ]))
        defer { h.env.cleanup() }
        for name in ["a.txt", "b.txt"] { try await h.ingest(name, text: name) }
        let tied = LabelSuggestion(kind: .sender, value: "EDP Comercail", into: "EDP Comercial", similarity: 0.97, reason: .writtenAlike)
        let outcome = try await h.labels.decide(tied, .same, trace: nil)
        #expect(outcome?.rule?.target == "EDP Comercial", "as many documents have each: the one the suggestion keeps")
        let reversed = LabelSuggestion(kind: .sender, value: "EDP Comercial", into: "EDP Comercail", similarity: 0.97, reason: .writtenAlike)
        let more = try await Harness.make(analyzer: PerFileAnalyzer(labels: [
            "a.txt": [Self.label(.sender, "EDP Comercial")], "b.txt": [Self.label(.sender, "EDP Comercial")],
            "c.txt": [Self.label(.sender, "EDP Comercail")],
        ]))
        defer { more.env.cleanup() }
        for name in ["a.txt", "b.txt", "c.txt"] { try await more.ingest(name, text: name) }
        #expect(try await more.labels.decide(reversed, .same, trace: nil)?.rule?.target == "EDP Comercial",
                "more documents have the suggestion's value now: it is the one kept, counted where the merge is made")
    }

    // MARK: When nothing is judged

    @Test func aPairWithoutAValidAnswerIsSetAsideUntilTheNextStart() async throws {
        let h = try await Self.archive()
        defer { h.env.cleanup() }
        let judging = StubJudging(nil)
        let judge = Self.judge(h, judging)
        let (first, second) = (await judge.judgeNext(), await judge.judgeNext())
        #expect(first == .judged && second == .judged, "each pair is asked")
        #expect(await judge.judgeNext() == .idle(nil), "and neither again while the judge runs")
        #expect(try await h.services.labels.rules().isEmpty, "nothing is decided without a judgement")
        let outcomes = try await h.env.database.reader.read { db in
            try TraceRecord.filter(Column("source") == TraceSource.labels.rawValue).fetchAll(db).map(\.outcome)
        }
        #expect(outcomes == [LabelJudge.unansweredOutcome, LabelJudge.unansweredOutcome], "each trace says it went unanswered")
        let next = Self.judge(h, StubJudging(.different))
        #expect(await next.judgeNext() == .judged, "the next start asks again")
    }

    @Test func aPairWaitsForOllamaUnderOneTraceAndForAModelThatIsMissing() async throws {
        let h = try await Self.archive()
        defer { h.env.cleanup() }
        let away = Mutex(true)
        let judging = StubJudging { _ in
            if away.withLock({ $0 }) { throw OllamaError.unreachable("connection refused") }
            return LabelVerdict(judgement: .different, reason: "Two.", model: "stub", problem: nil)
        }
        let judge = Self.judge(h, judging)
        let config = h.env.config.ingest
        #expect(await judge.judgeNext() == .idle(config.retryDelays.last), "Ollama away: the pair waits ingest.retryDelays.last seconds")
        #expect(await judge.judgeNext() == .idle(config.retryDelays.last), "and nothing is asked meanwhile")
        #expect(judging.pairs.count == 1, "the model was asked once")
        away.withLock { $0 = false }
        try await h.env.time.sleep(seconds: config.retryDelays.last)
        #expect(await judge.judgeNext() == .judged, "once the wait is over, it is judged")
        let traces = try await h.env.database.reader.read { db in
            try TraceRecord.filter(Column("source") == TraceSource.labels.rawValue).fetchAll(db)
        }
        #expect(traces.map(\.outcome) == [LabelJudgement.different.rawValue] && traces.first?.attempt == 2,
                "under the one trace the wait left, taken up by the next attempt")

        let missing = Self.judge(h, StubJudging { _ in throw OllamaError.modelNotFound("ministral-3:14b") })
        #expect(await missing.judgeNext() == .idle(config.modelRecheckSeconds), "a model missing waits ingest.modelRecheckSeconds")
    }

    @Test func aPairWhoseJudgingFailsOtherwiseIsSetAsideAndTheNextIsJudged() async throws {
        let h = try await Self.archive()
        defer { h.env.cleanup() }
        let judging = StubJudging { pair in
            if pair.kind == .sender { throw OllamaError.http(status: 500, body: "boom") }
            return LabelVerdict(judgement: .different, reason: "Two.", model: "stub", problem: nil)
        }
        let judge = Self.judge(h, judging)
        let (first, second) = (await judge.judgeNext(), await judge.judgeNext())
        #expect(first == .judged && second == .judged, "the failure costs the pair, not the rest")
        #expect(try await h.services.labels.rules().map(\.kind) == [.party], "the next pair is judged")
    }

    @Test func nothingIsJudgedWhileArrumatorIsPausedOrFilesWaitToBeFiled() async throws {
        let h = try await Self.archive()
        defer { h.env.cleanup() }
        let judging = StubJudging(.different)
        let judge = Self.judge(h, judging)
        try await h.env.settings.update { $0.paused = true }
        #expect(await judge.judgeNext() == .idle(nil), "paused, it waits")
        try await h.env.settings.update { $0.paused = false }
        let waiting = try h.env.drop("october.txt", text: "October")
        await h.coordinator.enqueue(waiting)
        #expect(await judge.judgeNext() == .idle(nil), "a file waiting to be filed comes first")
        #expect(judging.pairs.isEmpty, "the model was asked nothing")
        await h.coordinator.drain()
        #expect(await judge.judgeNext() == .judged, "once it is filed, the pairs are judged")
    }

    @Test func aPairARuleOfTheUsersDecidesIsNeverJudgedThoughBothLabelsAreInUse() async throws {
        let h = try await Self.archive()
        defer { h.env.cleanup() }
        // A rename that changes only the case leaves a rule about a label still on documents.
        try await h.labels.rename(Self.label(.sender, "EDP Comercial"), to: "EDP COMERCIAL")
        #expect(try await h.services.labels.suggestions().map(\.kind) == [.party], "the senders' pair is decided by the user's rule")
        let judging = StubJudging(.different)
        let judge = Self.judge(h, judging)
        let (first, second) = (await judge.judgeNext(), await judge.judgeNext())
        #expect(first == .judged && second == .idle(nil), "one pair is judged, and then nothing: no pair is asked about twice")
        #expect(judging.pairs.map(\.value) == ["Mario Silva"], "and never the pair the rule decides")
    }

    @Test func aPairSetAsideHoldsUpNoneBeyondTheLimitOfPairsWorkedOut() async throws {
        let h = try await Self.archive()
        defer { h.env.cleanup() }
        var services = h.services
        services.config.labels.vocabulary.suggestionLimit = 1
        let judging = StubJudging { pair in
            LabelVerdict(judgement: pair.kind == .sender ? nil : .different, reason: "Two.", model: "stub", problem: nil)
        }
        let judge = LabelJudge(services: services, judging: judging)
        let (first, second) = (await judge.judgeNext(), await judge.judgeNext())
        #expect(first == .judged && second == .judged, "the pair without an answer is set aside, and the next is worked out in its place")
        #expect(judging.pairs.map(\.value) == ["EDP Comercail", "Mario Silva"], "though only one pair is worked out at once")
    }

    @Test func aTraceLeftWaitingIsTakenUpOnlyByItsOwnPair() async throws {
        let h = try await Self.archive()
        defer { h.env.cleanup() }
        let away = Mutex(true)
        let judging = StubJudging { _ in
            if away.withLock({ $0 }) { throw OllamaError.unreachable("connection refused") }
            return LabelVerdict(judgement: .different, reason: "Two.", model: "stub", problem: nil)
        }
        let judge = Self.judge(h, judging)
        _ = await judge.judgeNext()
        // The senders' pair waits; meanwhile the user decides it.
        try await h.labels.keepApart(Self.label(.sender, "EDP Comercail"), from: "EDP Comercial")
        away.withLock { $0 = false }
        try await h.env.time.sleep(seconds: h.env.config.ingest.retryDelays.last)
        #expect(await judge.judgeNext() == .judged, "the next pair is judged")
        let traces = try await h.env.database.reader.read { db in
            try TraceRecord.filter(Column("source") == TraceSource.labels.rawValue).order(Column("id")).fetchAll(db)
        }
        #expect(traces.map(\.outcome) == [LabelJudge.decidedMeanwhileOutcome, LabelJudgement.different.rawValue],
                "the parties' pair has a trace of its own, and the senders' says it was decided meanwhile: \(traces.map(\.outcome))")
    }

    @Test func aPairThatWaitedIsTheSameWhicheverOfItsLabelsMoreDocumentsHave() async throws {
        let (edp, typo) = ([Self.label(.sender, "EDP Comercial")], [Self.label(.sender, "EDP Comercail")])
        let h = try await Harness.make(analyzer: PerFileAnalyzer(labels: [
            "july.txt": edp, "august.txt": edp, "september.txt": typo, "october.txt": typo, "november.txt": typo,
        ]))
        defer { h.env.cleanup() }
        for name in ["july.txt", "august.txt", "september.txt"] { try await h.ingest(name, text: "A bill: \(name)") }
        let away = Mutex(true)
        let judging = StubJudging { _ in
            if away.withLock({ $0 }) { throw OllamaError.unreachable("connection refused") }
            return LabelVerdict(judgement: .different, reason: "Two.", model: "stub", problem: nil)
        }
        let judge = Self.judge(h, judging)
        _ = await judge.judgeNext()
        // While it waits, two more bills come from the misspelt sender, which more documents have now.
        for name in ["october.txt", "november.txt"] { try await h.ingest(name, text: "A bill: \(name)") }
        away.withLock { $0 = false }
        try await h.env.time.sleep(seconds: h.env.config.ingest.retryDelays.last)
        #expect(await judge.judgeNext() == .judged, "the pair is judged")
        #expect(judging.pairs.map(\.into) == ["EDP Comercial", "EDP Comercail"], "written the other way round now")
        let traces = try await h.env.database.reader.read { db in
            try TraceRecord.filter(Column("source") == TraceSource.labels.rawValue).fetchAll(db)
        }
        #expect(traces.map(\.outcome) == [LabelJudgement.different.rawValue] && traces.first?.attempt == 2,
                "under the one trace the wait left, as it is the same pair: \(traces.map(\.outcome))")
    }

    @Test func aTraceLeftWaitingEndsAsStoppedAtAStop() async throws {
        let h = try await Self.archive()
        defer { h.env.cleanup() }
        let judge = Self.judge(h, StubJudging { _ in throw OllamaError.unreachable("connection refused") })
        #expect(await judge.judgeNext() == .idle(h.env.config.ingest.retryDelays.last), "the pair waits for Ollama")
        await judge.stop()
        let outcomes = try await h.env.database.reader.read { db in
            try TraceRecord.filter(Column("source") == TraceSource.labels.rawValue).fetchAll(db).map(\.outcome)
        }
        #expect(outcomes == [LabelJudge.stoppedOutcome], "its trace no longer says it waits, as nothing takes it up: \(outcomes)")
    }

    @Test func nothingIsJudgedWhileTheMacsPowerKeepsTheQueuesWaiting() async throws {
        let h = try await Self.archive()
        defer { h.env.cleanup() }
        let hot = Mutex(true)
        var services = h.services
        services.power = {
            PowerState(onBattery: false, batteryPercent: nil, thermal: hot.withLock { $0 } ? .critical : .nominal, lowPowerMode: false)
        }
        let judging = StubJudging(.different)
        let judge = LabelJudge(services: services, judging: judging)
        #expect(await judge.judgeNext() == .idle(h.env.config.power.recheckSeconds), "too hot, it looks again after power.recheckSeconds")
        #expect(judging.pairs.isEmpty, "and asks the model nothing")
        hot.withLock { $0 = false }
        #expect(await judge.judgeNext() == .judged, "cool again, it judges")
    }

    // MARK: The worker

    @Test func aSecondStartWhileTheFirstSubscribesMakesNoSecondWorker() async throws {
        let h = try await Self.archive()
        defer { h.env.cleanup() }
        let judge = Self.judge(h, StubJudging(.different))
        // The queue's changes are subscribed to only once the test lets them be, so the first start waits there.
        let subscribing = Mutex(0)
        let subscribed = Doorbell()
        let secondEnded = Mutex(false)
        let statuses: @Sendable () async -> AsyncStream<IngestStatus> = {
            subscribing.withLock { $0 += 1 }
            await subscribed.wait(timeout: nil, time: h.env.time)
            return AsyncStream { _ in }
        }
        let first = Task { await judge.start(followingStatuses: statuses) }
        try #require(await Patience.until { subscribing.withLock { $0 } == 1 }, "the first start subscribes")
        let second = Task {
            await judge.start(followingStatuses: statuses)
            secondEnded.withLock { $0 = true }
        }
        try #require(await Patience.until { secondEnded.withLock { $0 } || subscribing.withLock { $0 } == 2 }, "the second start is made")
        subscribed.ring()
        _ = await (first.value, second.value)
        #expect(subscribing.withLock { $0 } == 1, "the second start does nothing: the first claimed the worker")
        #expect(await Patience.until { (try? await h.services.labels.rules().count) == 2 && judge.doorbell.isWaitedOn },
                "both pairs are judged, and the worker waits")
        await judge.stop()
        #expect(!judge.doorbell.isWaitedOn, "and once it stops, no worker is left waiting")
    }

    @Test func theWorkerJudgesOnceThePauseIsOverThoughNothingElseChanges() async throws {
        let h = try await Self.archive()
        defer { h.env.cleanup() }
        let judging = StubJudging(.different)
        let judge = Self.judge(h, judging)
        try await h.env.settings.update { $0.paused = true }
        // No change of the queue rings, nor of History, as when another process ends the pause.
        await judge.start(followingStatuses: { AsyncStream { _ in } })
        try #require(await Patience.until { judge.doorbell.isWaitedOn }, "paused, it waits")
        try await h.env.settings.update { $0.paused = false }
        #expect(await Patience.until { judging.pairs.count == 2 }, "the pause over, the settings' change has it judge")
        await judge.stop()
    }

    @Test func theWorkerJudgesOnceTheFilesItGaveWayToAreFiled() async throws {
        let h = try await Self.archive()
        defer { h.env.cleanup() }
        let judging = StubJudging(.different)
        let judge = Self.judge(h, judging)
        // A file waits to be filed as the worker starts: it gives way, and waits.
        await h.coordinator.enqueue(try h.env.drop("october.txt", text: "October"))
        await judge.start(following: h.coordinator)
        try #require(await Patience.until { judge.doorbell.isWaitedOn }, "it waits while a file waits to be filed")
        #expect(judging.pairs.isEmpty, "and asks the model nothing meanwhile")
        // Filed, its job ends with no change to History; the queue's own change wakes the worker.
        await h.coordinator.drain()
        #expect(await Patience.until { judging.pairs.count == 2 }, "once the file is filed, the pairs are judged")
        await judge.stop()
    }

    @Test func theWorkerJudgesWhatAChangeBringsAndStops() async throws {
        let h = try await Harness.make(analyzer: PerFileAnalyzer(labels: [
            "maria.txt": [Self.label(.party, "Maria Silva")], "mario.txt": [Self.label(.party, "Mario Silva")],
        ]))
        defer { h.env.cleanup() }
        let judge = Self.judge(h, StubJudging(.different))
        await judge.start(following: h.coordinator)
        try #require(await Patience.until { judge.doorbell.isWaitedOn }, "with nothing to judge, it waits")
        for name in ["maria.txt", "mario.txt"] { try await h.ingest(name, text: name) }
        judge.wake()
        #expect(await Patience.until { (try? await h.services.labels.rules().count) == 1 }, "woken by a change, it judges the pair it brought")
        await judge.stop()
        await judge.stop()
    }
}
