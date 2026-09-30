/// The complete corpus, in the order it is written to expected.json.
enum Catalog {
    static func fixtures(seed: UInt64) -> [Fixture] {
        let cast = Cast(seed: seed)
        let fixtures = PortugueseFixtures.all(cast: cast, seed: seed)
            + RussianFixtures.all(cast: cast, seed: seed)
            + EnglishFixtures.all(cast: cast, seed: seed)
            + InternationalFixtures.all(seed: seed)
            + NegativeFixtures.all(cast: cast, seed: seed)
        let files = fixtures.map(\.record.file)
        precondition(Set(files).count == files.count, "duplicate fixture paths")
        return fixtures
    }

    /// Top-level folders the generator owns inside the output directory.
    static let folders = ["pt", "ru", "en", "intl", "negative"]
}
