/// Everything a stream sends, in order, read from a task of its own: a test waits for what it needs with
/// `Patience.until`, so a stream that never sends fails the test instead of hanging the run, as awaiting `next()` inline
/// would. `stop()` ends the reading.
public actor Collected<Element: Sendable> {
    public private(set) var all: [Element] = []
    private var reading: Task<Void, Never>?

    public init() {}

    /// Reads `stream` from now on.
    public static func reading(_ stream: AsyncStream<Element>) async -> Collected<Element> {
        let collected = Collected<Element>()
        await collected.follow(stream)
        return collected
    }

    private func follow(_ stream: AsyncStream<Element>) {
        reading = Task { [weak self] in
            for await element in stream { await self?.add(element) }
        }
    }

    private func add(_ element: Element) { all.append(element) }

    /// Stops reading the stream.
    public func stop() { reading?.cancel() }
}
