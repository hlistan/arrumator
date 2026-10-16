import Foundation

/// What the search field shows at one moment: the query, the documents found by its words, how far the comparison by
/// meaning has come, and whether anything more will come for this query.
public struct TypedSearchState: Sendable, Hashable {
    public var query: String
    /// What the query found; nil until the words of `query` have been searched.
    public var results: SearchResults?
    public var meaning: MeaningProgress
    /// Nothing more will come for this query, until the index changes.
    public var settled: Bool
    /// What a search that failed (`localizedDescription`), never what stopping it is.
    public var failure: String?

    public init(query: String, results: SearchResults?, meaning: MeaningProgress, settled: Bool, failure: String? = nil) {
        self.query = query
        self.results = results
        self.meaning = meaning
        self.settled = settled
        self.failure = failure
    }

    /// The search for this query failed before it found anything: there is nothing to list for it, and the documents the query
    /// before found are not its results. A search that failed after it found some, as the same query searched again, still
    /// has them, and one that waits for its words has not failed.
    public var failedBeforeFinding: Bool { settled && failure != nil && results == nil }

    /// Nothing typed: nothing looked for.
    public static let idle = TypedSearchState(query: "", results: nil, meaning: .pending, settled: true)
}

/// How far the comparison of a query with the documents by meaning has come.
public enum MeaningProgress: Sendable, Hashable {
    /// Not begun: typing has not paused, or return was not pressed.
    case pending
    /// Ollama is being asked for the query's meaning.
    case looking
    /// The documents were compared with it.
    case compared
    /// They were not, and why.
    case without(WithoutMeaning)
}

/// The search of what is typed in the search field: the words of each query at once, and its meaning once typing
/// pauses, or at return, with one automatic request to Ollama for each query: return asks again, as a person's request,
/// when Ollama was away or failed. A newer query cancels the one before, so the results of an older query never replace
/// a newer one's, and a change of the index searches the query again without asking Ollama again. The timing is decided here, where a test clock reaches it, and the app only shows the states.
public actor TypedSearch {
    public enum Input: Sendable, Equatable {
        /// The field now holds this text.
        case typed(String)
        /// Return was pressed: the meaning is asked for now, unless it was compared or is being asked for.
        case submitted
        /// The index changed: the documents may differ.
        case indexChanged
    }

    private let search: SearchService
    private let meaningDelay: Double
    private let time: any TimeSource
    private var query = ""
    /// Which query's search is the current one: a task whose generation is no longer this publishes nothing.
    private var generation = 0
    /// The searches that have not ended, each removed by itself as it ends: those a newer query cancelled are among them
    /// until they notice, so what waits for the search to end waits for them too.
    private var searches: [Int: Task<Void, Never>] = [:]
    private var searchesStarted = 0
    /// When the meaning may be asked for: one pause after the query was typed, which an index change keeps.
    private var meaningDue: Date?
    /// How the last comparison by meaning of this query ended: nil while none was tried, `.some(nil)` when it compared.
    private var lastMeaning: WithoutMeaning??
    /// Whether the documents were compared with the query by meaning: what return has nothing to add to.
    private var compared: Bool {
        if case .some(.none) = lastMeaning { true } else { false }
    }
    private var requestInFlight = false
    private var changedWhileInFlight = false
    private var state = TypedSearchState.idle
    private var followers: [UUID: AsyncStream<TypedSearchState>.Continuation] = [:]

    public init(search: SearchService, meaningDelay: Double, time: any TimeSource) {
        self.search = search
        self.meaningDelay = meaningDelay
        self.time = time
    }

    /// The state now, then each change of it, for as long as the stream is read.
    public func states() -> AsyncStream<TypedSearchState> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<TypedSearchState>.makeStream(bufferingPolicy: .unbounded)
        continuation.yield(state)
        followers[id] = continuation
        continuation.onTermination = { [weak self] _ in Task { await self?.removeFollower(id) } }
        return stream
    }

    private func removeFollower(_ id: UUID) { followers[id] = nil }

    public func take(_ input: Input) {
        switch input {
        case let .typed(text): typed(text)
        case .submitted: submitted()
        case .indexChanged: indexChanged()
        }
    }

    /// Ends the search under way and waits for it, and goes back to nothing typed: the query it was for is looked for no
    /// more, and nothing is published after this returns. What is typed while it waits starts a search of its own, which
    /// it ends too. What is typed next is looked for as before, as when the runtime that stopped for a switch that
    /// failed starts again.
    public func stop() async {
        generation += 1
        while let running = searches.values.first {
            cancelSearches()
            await running.value
        }
        // After the last wait, so what was typed during one is forgotten with the rest, and no task of it still runs.
        generation += 1
        query = ""
        meaningDue = nil
        lastMeaning = nil
        requestInFlight = false
        changedWhileInFlight = false
        publish(.idle)
    }

    /// Returns when no search is under way, those cancelled and those an end of one starts included, without ending
    /// any: the states say a query is settled before the search that settled it has returned, so a caller that waits for
    /// nothing more to come for it waits for this.
    public func untilIdle() async {
        while let running = searches.values.first { await running.value }
    }

    private func typed(_ text: String) {
        guard text != query else { return }
        query = text
        generation += 1
        lastMeaning = nil
        requestInFlight = false
        changedWhileInFlight = false
        cancelSearches()
        guard !text.isEmpty else {
            meaningDue = nil
            publish(.idle)
            return
        }
        meaningDue = time.now().addingTimeInterval(meaningDelay)
        publish(TypedSearchState(query: text, results: nil, meaning: .pending, settled: false))
        start()
    }

    /// Return asks for the meaning unless it was compared or is being asked for, also when Ollama was away or failed:
    /// that is one request more, which the person made, where the automatic one is one for each query.
    private func submitted() {
        guard !query.isEmpty, !compared, !requestInFlight else { return }
        lastMeaning = nil
        generation += 1
        meaningDue = time.now()
        start()
    }

    private func indexChanged() {
        guard !query.isEmpty else { return }
        if requestInFlight {
            changedWhileInFlight = true
            return
        }
        generation += 1
        start()
    }

    private func start() {
        cancelSearches()
        let (text, current) = (query, generation)
        searchesStarted += 1
        let id = searchesStarted
        searches[id] = Task {
            await self.run(text, generation: current)
            self.ended(id)
        }
    }

    private func cancelSearches() {
        for each in searches.values { each.cancel() }
    }

    private func ended(_ id: Int) { searches[id] = nil }

    private func isCurrent(_ current: Int) -> Bool { generation == current && !Task.isCancelled }

    private func publish(_ next: TypedSearchState) {
        guard next != state else { return }
        state = next
        for follower in followers.values { follower.yield(next) }
    }

    private func run(_ text: String, generation current: Int) async {
        do {
            if let last = lastMeaning {
                try await again(text, generation: current, after: last)
            } else {
                try await first(text, generation: current)
            }
        } catch is CancellationError {
            return
        } catch {
            guard isCurrent(current) else { return }
            // A change that came while the request failed belongs to it: a later search that succeeds does not run again for it.
            changedWhileInFlight = false
            // Whatever it was looking for is looked for no more: a failure leaves the meaning not compared.
            publish(TypedSearchState(query: text, results: state.query == text ? state.results : nil,
                                     meaning: state.meaning == .looking ? .pending : state.meaning, settled: true,
                                     failure: error.localizedDescription))
        }
    }

    /// A query not yet compared by meaning: its words at once, then its meaning after the pause.
    private func first(_ text: String, generation current: Int) async throws {
        let words = try await search.search(SearchQuery(text: text, meaning: .wordsOnly))
        guard isCurrent(current) else { return }
        guard words.withoutMeaning == .notAsked else {
            // Nothing to look for, or too short to mean anything: no request is made, so there is nothing to wait for.
            publish(TypedSearchState(query: text, results: words, meaning: .without(words.withoutMeaning ?? .notAsked), settled: true))
            return
        }
        publish(TypedSearchState(query: text, results: words, meaning: .pending, settled: false))
        if let due = meaningDue {
            let wait = due.timeIntervalSince(time.now())
            if wait > 0 { try await time.sleep(seconds: wait) }
        }
        guard isCurrent(current) else { return }
        publish(TypedSearchState(query: text, results: words, meaning: .looking, settled: false))
        try await full(text, generation: current)
    }

    /// A query whose meaning was tried: Ollama is not asked again if it was away or failed; otherwise the query's vector is
    /// kept, so the search by meaning asks nothing.
    private func again(_ text: String, generation current: Int, after last: WithoutMeaning?) async throws {
        if let reason = last, reason.askedOllama {
            let words = try await search.search(SearchQuery(text: text, meaning: .wordsOnly))
            guard isCurrent(current) else { return }
            publish(TypedSearchState(query: text, results: words, meaning: .without(reason), settled: true))
            return
        }
        try await full(text, generation: current)
    }

    /// The words and meaning, asking Ollama once.
    private func full(_ text: String, generation current: Int) async throws {
        requestInFlight = true
        let results: SearchResults
        do {
            // Whatever ends the request, the query is no longer being asked for, unless a newer one has taken over.
            defer { if generation == current { requestInFlight = false } }
            results = try await search.search(SearchQuery(text: text, meaning: .askOnce))
        }
        guard isCurrent(current) else { return }
        lastMeaning = .some(results.withoutMeaning)
        publish(TypedSearchState(query: text, results: results, meaning: results.withoutMeaning.map(MeaningProgress.without) ?? .compared,
                                 settled: true))
        if changedWhileInFlight {
            changedWhileInFlight = false
            indexChanged()
        }
    }
}
