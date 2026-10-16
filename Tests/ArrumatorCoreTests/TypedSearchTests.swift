import ArrumatorCore
import ArrumatorTesting
import Foundation
import GRDB
import Synchronization
import Testing

/// The search of what is typed: the words of each query at once, its meaning once typing pauses, one request to Ollama
/// for each settled query, and no result of an older query after a newer one's. Each wait is for a state to be published.
@Suite(.timeLimit(.minutes(1))) struct TypedSearchTests {
    let fixtures = SearchTests()

    struct World {
        let db: AppDatabase
        let typed: TypedSearch
        let states: Collected<TypedSearchState>
        let meter: Int64

        var all: [TypedSearchState] { get async { await states.all } }
        var last: TypedSearchState? { get async { await states.all.last } }
        func settled(_ query: String) async -> Bool {
            await Patience.until { await last.map { $0.query == query && $0.settled } ?? false }
        }
        /// Ends what the test started: its reading of the states and the search.
        func end() async {
            await states.stop()
            await typed.stop()
        }
    }

    func world(embedder: (any Embedder)?, time: any TimeSource = TestTime(.advances), delay: Double? = nil,
               vectors: [(Int64, Float)]? = nil, queryCacheSize: Int? = nil) async throws -> World {
        let db = try AppDatabase.inMemory()
        let meter = try await fixtures.insert(db, title: "Meter reading", body: "kilowatt hours read on the meter", sender: "EDP")
        let config = try PipelineConfig.bundledDefaults()
        var searching = config.search
        if let queryCacheSize { searching.queryCacheSize = queryCacheSize }
        let search = SearchService(database: db, vectors: await SearchTests.vectors(vectors ?? [(meter, 0.9)]), embedder: embedder,
                                   config: searching, time: TestTime(.advances))
        let typed = TypedSearch(search: search, meaningDelay: delay ?? config.interface.searchMeaningDelay, time: time)
        return World(db: db, typed: typed, states: await Collected.reading(await typed.states()), meter: meter)
    }

    @Test func typingQuicklyAsksNothingUntilTypingPausesOrReturnIsPressed() async throws {
        let embedder = SearchTests.CountingEmbedder()
        let w = try await world(embedder: embedder, time: TestTime(.blocks))
        for text in ["k", "ki", "kilowatt"] { await w.typed.take(.typed(text)) }
        #expect(await Patience.until { let last = await w.last; return last?.query == "kilowatt" && last?.results != nil }, "the words of the last query show")
        let words = try #require(await w.last)
        #expect(words.results?.hits.map(\.id) == [w.meter] && words.meaning == .pending && !words.settled, "while its meaning is still to be asked")
        #expect(embedder.asked == 0, "and Ollama is asked nothing while the pause does not end")

        await w.typed.take(.submitted)
        #expect(await w.settled("kilowatt"), "return asks for the meaning at once")
        #expect(await w.last?.meaning == .compared && embedder.asked == 1, "once")
        await w.end()
    }

    @Test func aSettledQueryAsksOnceAndAnIndexChangeAsksNothingAgain() async throws {
        let embedder = SearchTests.CountingEmbedder()
        let w = try await world(embedder: embedder)
        await w.typed.take(.typed("kilowatt"))
        #expect(await w.settled("kilowatt") && embedder.asked == 1, "the settled query asked once")
        let added = try await fixtures.insert(w.db, title: "Second meter", body: "more kilowatt hours", sender: "EDP")
        await w.typed.take(.indexChanged)
        #expect(await Patience.until { await w.last?.results?.hits.map(\.id).contains(added) == true }, "the next state holds the document filed")
        #expect(await w.last?.meaning == .compared && embedder.asked == 1, "and Ollama was not asked again")
        await w.end()
    }

    @Test func ollamaAwayIsAskedOnceAndNotAgainOnAnIndexChange() async throws {
        let embedder = SearchTests.FailingEmbedder(error: OllamaError.unreachable("down"))
        let w = try await world(embedder: embedder)
        await w.typed.take(.typed("kilowatt"))
        #expect(await w.settled("kilowatt"), "the query settles")
        #expect(embedder.retried.calls.withLock { $0 } == [false], "Ollama was asked once, without asking again after delays")
        let away = await w.last
        #expect(away?.meaning == .without(.ollamaAway) && away?.results?.hits.map(\.id) == [w.meter], "the words stand, and it says why")
        let added = try await fixtures.insert(w.db, title: "Second meter", body: "more kilowatt hours", sender: "EDP")
        await w.typed.take(.indexChanged)
        #expect(await Patience.until { await w.last?.results?.hits.map(\.id).contains(added) == true }, "the new document shows")
        let still = await w.last
        #expect(still?.meaning == .without(.ollamaAway) && still?.settled == true, "still without meaning")
        #expect(embedder.retried.calls.withLock { $0 } == [false], "and Ollama was not asked again")
        await w.end()
    }

    @Test func aNewerQueryCancelsTheOlderAndItsResultsNeverReplaceTheNewer() async throws {
        let embedder = LingeringEmbedder()
        let w = try await world(embedder: embedder)
        _ = try await fixtures.insert(w.db, title: "Gas bill", body: "gas supply", sender: "Galp")
        // The older query finds its document by its words too, so its search after the answer reads nothing more from the
        // index, which would stop it by cancellation: only the search's own check keeps what it found from being published.
        await w.typed.take(.typed("kilowatt"))
        #expect(await Patience.until { await embedder.asked.count == 1 }, "the older query asks for its meaning")
        await w.typed.take(.typed("gas"))
        #expect(await Patience.until { await embedder.asked.count == 2 }, "the newer one asks for its own")
        // The newer answer comes first and the older after it, as it can: the older search is then the only one left, and
        // the test waits for it to end before it looks at what was published.
        await embedder.release(containing: "gas")
        #expect(await w.settled("gas"), "the newer query settles")
        await embedder.release(containing: "kilowatt")
        await w.typed.untilIdle()
        // Clearing the field publishes idle, which every state before it has reached the reader by: what the older search
        // published, if it did, is among them.
        await w.typed.take(.typed(""))
        #expect(await Patience.until { await w.last == TypedSearchState.idle }, "an empty field is idle")
        let states = await w.all
        let firstGas = try #require(states.firstIndex { $0.query == "gas" }, "the newer query was published")
        #expect(states[firstGas...].dropLast().allSatisfy { $0.query == "gas" }, "no state of the older query follows it: \(states.map(\.query))")
        await w.end()
    }

    @Test func anIndexChangeWhileMeaningIsAskedAsksOnceAndShowsTheNewDocument() async throws {
        let embedder = SearchTests.HeldEmbedder()
        let w = try await world(embedder: embedder)
        await w.typed.take(.typed("kilowatt"))
        #expect(await Patience.until { await embedder.asked == 1 }, "the meaning is being asked for")
        let added = try await fixtures.insert(w.db, title: "Second meter", body: "more kilowatt hours", sender: "EDP")
        await w.typed.take(.indexChanged)
        await embedder.release()
        #expect(await Patience.until { let last = await w.last; return last?.settled == true && last?.results?.hits.map(\.id).contains(added) == true },
                "the results come to hold the document filed meanwhile")
        #expect(await embedder.asked == 1, "with one request in all")
        await w.end()
    }

    @Test func anIndexChangeDuringThePauseKeepsItsEnd() async throws {
        let clock = TestTime(.advances)
        let log = SleepLog(clock)
        let delay = try PipelineConfig.bundledDefaults().interface.searchMeaningDelay
        let embedder = SearchTests.CountingEmbedder()
        let w = try await world(embedder: embedder, time: log, delay: delay)
        await w.typed.take(.typed("kilowatt"))
        #expect(await Patience.until { log.sleeps == [delay] }, "the pause is the delay: \(log.sleeps)")
        clock.advance(by: delay / 2)
        await w.typed.take(.indexChanged)
        #expect(await Patience.until { log.sleeps == [delay, delay / 2] }, "a change halfway through leaves the other half: \(log.sleeps)")
        #expect(embedder.asked == 0, "and meaning is not asked while the pause lasts")
        await w.end()
    }

    @Test(arguments: [true, false])
    func nothingToLookForAndTooShortAskNothing(nothingToLookFor: Bool) async throws {
        let minChars = try PipelineConfig.bundledDefaults().search.minSemanticQueryChars
        let text = nothingToLookFor ? "%%%" : String("kilowatt".prefix(minChars - 1))
        let embedder = SearchTests.CountingEmbedder()
        let w = try await world(embedder: embedder)
        await w.typed.take(.typed(text))
        #expect(await w.settled(text), "the query settles at once")
        #expect(embedder.asked == 0, "asking nothing of Ollama")
        #expect(await w.all.allSatisfy { $0.meaning != .looking }, "and never saying it is looking")
        await w.end()
    }

    @Test func aSearchThatFailsSaysWhy() async throws {
        let w = try await world(embedder: nil)
        try await w.db.writer.write { try $0.execute(sql: "DROP TABLE document_fts") }
        await w.typed.take(.typed("kilowatt"))
        #expect(await Patience.until { let last = await w.last; return last?.failure?.contains("document_fts") == true && last?.settled == true },
                "the failure, which names the table that failed, is published and the query settles")
        #expect(await w.last?.failedBeforeFinding == true, "it failed before it found anything: nothing to list for this query")
        #expect(await w.all.dropLast().allSatisfy { !$0.failedBeforeFinding }, "which no state before it says: waiting for the words has not failed")
        await w.end()
    }

    /// The page lists nothing for a query whose search failed, and not what the query before it found.
    @Test func aNewQueryThatFailsHasNoResultsOfTheQueryBeforeIt() async throws {
        let w = try await world(embedder: nil)
        _ = try await fixtures.insert(w.db, title: "Gas bill", body: "gas supply", sender: "Galp")
        await w.typed.take(.typed("kilowatt"))
        #expect(await w.settled("kilowatt"), "the first query settles")
        #expect(await w.last?.results?.hits.map(\.id) == [w.meter], "having found its document")
        try await w.db.writer.write { try $0.execute(sql: "DROP TABLE document_fts") }
        await w.typed.take(.typed("gas"))
        #expect(await Patience.until { let last = await w.last; return last?.query == "gas" && last?.settled == true && last?.failure != nil },
                "the second query fails and settles")
        let failed = try #require(await w.last)
        #expect(failed.results == nil && failed.failedBeforeFinding, "with no results, and so nothing for the page to list")
        #expect(!TypedSearchState.idle.failedBeforeFinding, "while nothing typed is not a failure")
        await w.end()
    }

    /// The failure of a search after it said it was looking for meaning no longer says so: it is not looking.
    @Test func aSearchThatFailsAfterLookingForMeaningDoesNotSayItIsStillLooking() async throws {
        let embedder = SearchTests.HeldEmbedder()
        let w = try await world(embedder: embedder, vectors: [(1, 0.9), (2, 0.9)])
        let gas = try await fixtures.insert(w.db, title: "Gas bill", body: "gas supply", sender: "Galp")
        #expect(gas == 2, "the second document is the one found by meaning alone, whose text is read last")
        await w.typed.take(.typed("kilowatt"))
        #expect(await Patience.until { await embedder.asked == 1 }, "the meaning is being asked for")
        #expect(await w.last?.meaning == .looking, "and the search says so")
        try await w.db.writer.write { try $0.execute(sql: "DROP TABLE document_text") }
        await embedder.release()
        #expect(await Patience.until { let last = await w.last; return last?.failure?.contains("document_text") == true && last?.settled == true },
                "the search fails, naming the table, and settles")
        #expect(await w.last?.meaning == .pending, "no longer looking for meaning: it was not compared")
        let kept = await w.last
        #expect(kept?.results?.hits.isEmpty == false && kept?.failedBeforeFinding == false, "what the words found stands, so the page keeps listing it")
        await w.end()
    }

    @Test func stoppingEndsTheSearchUnderWayAndWhatIsTypedNextIsLookedFor() async throws {
        let embedder = SearchTests.StalledEmbedder()
        let w = try await world(embedder: embedder)
        await w.typed.take(.typed("kilowatt"))
        #expect(await Patience.until { embedder.asked.fired }, "the meaning is being asked for")
        await w.typed.stop()
        #expect(await Patience.until { await w.last == TypedSearchState.idle }, "stopped, it is back to nothing typed")
        await w.typed.take(.typed("meter"))
        #expect(await Patience.until { let last = await w.last; return last?.query == "meter" && last?.results?.hits.map(\.id) == [w.meter] }, "a query typed after is searched")
        let states = await w.all
        let idle = try #require(states.lastIndex(of: .idle), "it went back to nothing typed")
        #expect(!states[idle...].contains { $0.query == "kilowatt" }, "and the stopped query published nothing more: \(states.map(\.query))")
        await w.end()
    }

    /// Holds each embedding asked for until the test lets it go, keeping which texts were asked and which were stopped
    /// meanwhile: a stopped request still waits to be let go, as a request to Ollama does until its connection ends.
    actor LingeringEmbedder: Embedder {
        nonisolated let modelId = SearchTests.FixedEmbedder.model
        private(set) var asked: [String] = []
        private(set) var stopped: [String] = []
        private var held: [(text: String, go: CheckedContinuation<Void, Never>)] = []

        func embed(_ texts: [String], retrying: Bool) async throws -> [[Float]] {
            let text = texts.joined(separator: " ")
            asked.append(text)
            await withTaskCancellationHandler {
                await withCheckedContinuation { held.append((text, $0)) }
            } onCancel: {
                Task { await self.stop(of: text) }
            }
            return texts.map { _ in [1, 0] }
        }

        private func stop(of text: String) { stopped.append(text) }

        /// Lets go the requests held for `text`, or all of them.
        func release(containing text: String? = nil) {
            let (going, staying) = (held.filter { text == nil || $0.text.contains(text ?? "") }, held.filter { !(text == nil || $0.text.contains(text ?? "")) })
            held = staying
            for each in going { each.go.resume() }
        }
    }

    /// Typing while the runtime is being stopped starts a search that nothing stops: `stop()` waits for the one it
    /// cancelled, and what is typed meanwhile is a search of its own, which it must end too.
    @Test func whatIsTypedWhileStoppingIsStoppedToo() async throws {
        let embedder = LingeringEmbedder()
        let w = try await world(embedder: embedder)
        await w.typed.take(.typed("kilowatt"))
        #expect(await Patience.until { await embedder.asked.count == 1 }, "the meaning is being asked for")
        let stopping = Task { await w.typed.stop() }
        #expect(await Patience.until { await embedder.stopped.count == 1 }, "stop cancelled the search and waits for it")
        await w.typed.take(.typed("meter"))
        #expect(await Patience.until { await embedder.asked.count == 2 }, "the query typed meanwhile asks for its meaning")
        await embedder.release(containing: "kilowatt")
        #expect(await Patience.until { await embedder.stopped.count == 2 }, "stop, once the first search ended, ended the one typed meanwhile too")
        await embedder.release()
        await stopping.value
        #expect(await Patience.until { await w.last == TypedSearchState.idle }, "stopped, it is back to nothing typed")
        let states = await w.all
        let idle = try #require(states.lastIndex(of: .idle), "it went back to nothing typed")
        #expect(!states[idle...].contains { $0.query == "meter" }, "and nothing of the query typed meanwhile follows: \(states.map(\.query))")
        await w.end()
    }

    /// An index change that came while a search was asking for the meaning belongs to that request: when it failed, a
    /// later search is not run again for it.
    @Test func anIndexChangeInFlightWhenTheSearchFailedRunsNoSearchOnceMoreWhenALaterOneSucceeds() async throws {
        let embedder = LingeringEmbedder()
        let w = try await world(embedder: embedder, vectors: [(1, 0.9), (2, 0.9)], queryCacheSize: 0)
        _ = try await fixtures.insert(w.db, title: "Gas bill", body: "gas supply", sender: "Galp")
        await w.typed.take(.typed("kilowatt"))
        #expect(await Patience.until { await embedder.asked.count == 1 }, "the meaning is being asked for")
        // The document found by meaning alone has its text read last, which is what fails.
        try await w.db.writer.write { try $0.execute(sql: "ALTER TABLE document_text RENAME TO document_text_away") }
        await w.typed.take(.indexChanged)
        await embedder.release()
        #expect(await Patience.until { let last = await w.last; return last?.failure != nil && last?.settled == true }, "the search fails and settles")

        try await w.db.writer.write { try $0.execute(sql: "ALTER TABLE document_text_away RENAME TO document_text") }
        await w.typed.take(.submitted)
        #expect(await Patience.until { await embedder.asked.count == 2 }, "return asks again")
        // Filed after this search read the words and before it ends, as a change after it began: only a search once more shows it.
        let added = try await fixtures.insert(w.db, title: "Second meter", body: "more kilowatt hours", sender: "EDP")
        await embedder.release()
        #expect(await Patience.until { let last = await w.last; return last?.failure == nil && last?.meaning == .compared && last?.settled == true }, "it succeeds")
        // Where a search once more would have begun, as the success published: the test waits for the searches to end.
        let idle = Signal()
        let idling = Task {
            await w.typed.untilIdle()
            idle.fire()
        }
        #expect(await Patience.until { await embedder.release(); return idle.fired }, "no search is left under way")
        idling.cancel()
        let states = await w.all
        #expect(!states.contains { $0.results?.hits.map(\.id).contains(added) == true }, "no search followed for the change the failed one had: \(states.map(\.query))")
        #expect(await embedder.asked.count == 2, "and Ollama was asked no more")
        await w.end()
    }

    /// An embedder that is away for its first request and answers every one after it, as Ollama coming back.
    final class ReturningEmbedder: Embedder {
        let modelId = SearchTests.FixedEmbedder.model
        private let count = Mutex(0)
        var asked: Int { count.withLock { $0 } }
        func embed(_ texts: [String], retrying: Bool) async throws -> [[Float]] {
            if count.withLock({ $0 += 1; return $0 }) == 1 { throw OllamaError.unreachable("down") }
            return texts.map { _ in [1, 0] }
        }
    }

    @Test func returnAsksAgainAfterOllamaWasAwayWhileAnIndexChangeDoesNot() async throws {
        let embedder = ReturningEmbedder()
        let w = try await world(embedder: embedder)
        await w.typed.take(.typed("kilowatt"))
        #expect(await w.settled("kilowatt"), "the query settles")
        let away = await w.last?.meaning
        #expect(embedder.asked == 1 && away == .without(.ollamaAway), "having asked once, and without meaning, Ollama being away")
        let added = try await fixtures.insert(w.db, title: "Second meter", body: "more kilowatt hours", sender: "EDP")
        await w.typed.take(.indexChanged)
        #expect(await Patience.until { await w.last?.results?.hits.map(\.id).contains(added) == true }, "the new document shows")
        let still = await w.last?.meaning
        #expect(embedder.asked == 1 && still == .without(.ollamaAway), "an index change does not ask Ollama again")

        await w.typed.take(.submitted)
        #expect(await Patience.until { await w.last?.meaning == .compared }, "return asks again, Ollama being back, and compares")
        #expect(embedder.asked == 2, "so the meaning was asked for twice in all")
        await w.end()
    }

    @Test func returnAfterTheMeaningWasComparedAsksNothingAndLosesNothingKnown() async throws {
        let embedder = SearchTests.CountingEmbedder()
        let w = try await world(embedder: embedder)
        await w.typed.take(.typed("kilowatt"))
        #expect(await w.settled("kilowatt"), "the query settles")
        #expect(await w.last?.meaning == .compared, "compared")
        let compared = await w.all.count
        await w.typed.take(.submitted)
        // Whatever return did is seen when the index changes after it: a query whose comparison was forgotten is searched
        // again from its words, which says it is pending, and one that is kept is shown compared at once.
        let added = try await fixtures.insert(w.db, title: "Second meter", body: "more kilowatt hours", sender: "EDP")
        await w.typed.take(.indexChanged)
        #expect(await Patience.until { let last = await w.last; return last?.settled == true && last?.results?.hits.map(\.id).contains(added) == true },
                "the new document shows")
        await w.typed.untilIdle()
        let after = await w.all.dropFirst(compared)
        #expect(after.allSatisfy { $0.meaning == .compared }, "every state after is compared: \(after.map(\.meaning))")
        #expect(embedder.asked == 1, "and Ollama was asked once")
        await w.end()
    }

    @Test func returnWhileTheMeaningIsBeingAskedForAsksNothingMore() async throws {
        let embedder = SearchTests.HeldEmbedder()
        let w = try await world(embedder: embedder)
        await w.typed.take(.typed("kilowatt"))
        #expect(await Patience.until { await embedder.asked == 1 }, "the meaning is being asked for")
        await w.typed.take(.submitted)
        await embedder.release()
        #expect(await w.settled("kilowatt"), "the query settles")
        await w.typed.untilIdle()
        #expect(await embedder.asked == 1, "with the one request it had")
        let states = await w.all
        let looking = try #require(states.firstIndex { $0.meaning == .looking }, "it said it was looking")
        #expect(states[looking...].allSatisfy { $0.meaning != .pending }, "and went back to waiting for no pause: \(states.map(\.meaning))")
        await w.end()
    }

    @Test func theSameTextAgainPublishesNothing() async throws {
        let w = try await world(embedder: SearchTests.CountingEmbedder())
        await w.typed.take(.typed("kilowatt"))
        #expect(await w.settled("kilowatt"), "the query settles")
        let settled = await w.all.count
        await w.typed.take(.typed("kilowatt"))
        // Typing the text again publishes at once if it is taken for a new query; clearing the field after it publishes
        // idle, which every state before it has reached the reader by.
        await w.typed.take(.typed(""))
        #expect(await Patience.until { await w.last == TypedSearchState.idle }, "an empty field is idle")
        #expect(await w.all.dropFirst(settled).map(\.query) == [""], "and between the settled query and idle there was no state: it is the same query")
        await w.end()
    }

    @Test func clearingTheFieldIsIdleAndAskedNothing() async throws {
        let embedder = SearchTests.CountingEmbedder()
        let w = try await world(embedder: embedder, time: TestTime(.blocks))
        await w.typed.take(.typed("kilowatt"))
        #expect(await Patience.until { await w.last?.results != nil }, "the words show")
        await w.typed.take(.typed(""))
        #expect(await Patience.until { await w.last == TypedSearchState.idle }, "an empty field is idle")
        await w.typed.take(.submitted)
        await w.typed.take(.indexChanged)
        // The clock blocks every pause, so a search that began would never end: a hang fails the test, not the run.
        let idle = Signal()
        let idling = Task {
            await w.typed.untilIdle()
            idle.fire()
        }
        #expect(await Patience.until { idle.fired }, "no search is left under way")
        idling.cancel()
        #expect(await w.last == TypedSearchState.idle && embedder.asked == 0, "and nothing more is looked for")
        await w.end()
    }
}
