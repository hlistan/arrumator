import ArrumatorCore
import ArrumatorTesting
import Foundation
import Testing

@Suite struct TaxonomyStoreTests {
    @Test func archiveStartsEmptyAndSystemFoldersAppearOnlyWhenNeeded() async throws {
        let env = try await TestEnvironment.make()
        defer { env.cleanup() }
        #expect(try await env.taxonomy.snapshot(root: env.archive).folders.isEmpty)
        let review = try await env.taxonomy.ensureSystemFolder(.needsReview, root: env.archive)
        #expect(review.role == .needsReview && !review.acceptsFiles)
        let again = try await env.taxonomy.ensureSystemFolder(.needsReview, root: env.archive)
        #expect(again.id == review.id)
        let snapshot = try await env.taxonomy.snapshot(root: env.archive)
        #expect(snapshot.folder(role: .duplicates) == nil)
        #expect(FileManager.default.fileExists(atPath: snapshot.url(for: review).appendingPathComponent(env.config.taxonomy.aboutFileName).path))
    }

    @Test func foldersAreCreatedOnDemandWithJohnnyDecimalCodes() async throws {
        let env = try await TestEnvironment.make()
        defer { env.cleanup() }
        let utilities = try await env.folder("Utilities", area: "Home", yearly: true)
        let telecom = try await env.folder("Internet and Phone", area: "Home")
        let taxes = try await env.folder("Taxes (Portugal)", area: "Money and Taxes", yearly: true)
        #expect(utilities.parentCode == "10-19" && utilities.code == "11")
        #expect(telecom.code == "12")
        #expect(taxes.parentCode == "20-29" && taxes.code == "21")
        #expect(utilities.yearSubfolders && utilities.acceptsFiles && utilities.origin == .learned)
        let snapshot = try await env.taxonomy.snapshot(root: env.archive)
        #expect(snapshot.url(for: utilities).path.hasSuffix("10-19 Home/11 Utilities"))
        #expect(FileManager.default.fileExists(atPath: env.archive.appendingPathComponent(env.config.taxonomy.indexFileName).path))
    }

    @Test func userEditsSurviveAndRenamesAreFollowed() async throws {
        let env = try await TestEnvironment.make()
        defer { env.cleanup() }
        let folder = try await env.folder("Utilities", area: "Home")
        var snapshot = try await env.taxonomy.snapshot(root: env.archive)
        let dir = snapshot.url(for: folder)
        let aboutURL = dir.appendingPathComponent(env.config.taxonomy.aboutFileName)
        try Data((try String(contentsOf: aboutURL, encoding: .utf8) + "\nPersonal note.\n").utf8).write(to: aboutURL)
        try await env.taxonomy.updateLearned(folderID: folder.id, root: env.archive,
                                             learned: LearnedBlock(examples: ["2026-07-05 EDP - Fatura.pdf"], correspondents: ["EDP"]))
        let text = try String(contentsOf: aboutURL, encoding: .utf8)
        #expect(text.contains("Personal note.") && text.contains("2026-07-05 EDP - Fatura.pdf"))
        let renamed = dir.deletingLastPathComponent().appendingPathComponent("\(folder.code) Energy and Water")
        try FileManager.default.moveItem(at: dir, to: renamed)
        let changes = try await env.taxonomy.sync(root: env.archive)
        #expect(changes.contains { $0.kind == .renamed && $0.code == folder.code })
        snapshot = try await env.taxonomy.snapshot(root: env.archive)
        #expect(snapshot.folder(code: folder.code)?.name == "Energy and Water")
        #expect(snapshot.folder(code: folder.code)?.id == folder.id)
        #expect(snapshot.folder(code: folder.code)?.learnedCorrespondents == ["EDP"])
    }

    @Test func handMadeFolderIsInferredUntilDescribed() async throws {
        let env = try await TestEnvironment.make()
        defer { env.cleanup() }
        let folder = try await env.folder("Utilities", area: "Home")
        let snapshot = try await env.taxonomy.snapshot(root: env.archive)
        let areaCode = try #require(folder.parentCode)
        let area = try #require(snapshot.folder(code: areaCode))
        try FileManager.default.createDirectory(at: snapshot.url(for: area).appendingPathComponent("15 Garden"),
                                                withIntermediateDirectories: true)
        let changes = try await env.taxonomy.sync(root: env.archive)
        #expect(changes.contains { $0.kind == .inferred && $0.code == "15" })
        #expect(try await env.taxonomy.snapshot(root: env.archive).folder(code: "15")?.acceptsFiles == false)
    }

    @Test func namesAreUniqueWithinAnArea() async throws {
        let env = try await TestEnvironment.make()
        defer { env.cleanup() }
        let first = try await env.folder("Taxes (Portugal)", area: "Money")
        let again = try await env.folder("taxes (portugal)", area: "Money")
        #expect(again.id == first.id)
        let elsewhere = try await env.folder("Taxes (Portugal)", area: "Home")
        #expect(elsewhere.id != first.id, "logic may give a topic a home in another area")
        let area = try await env.taxonomy.createArea(root: env.archive, name: "money", description: "", origin: .learned)
        #expect(area.code == first.parentCode)
        let lower = try await env.folder("medical records", area: "health")
        #expect(lower.name == "Medical records")
        #expect(try await env.taxonomy.snapshot(root: env.archive).areas.contains { $0.name == "Health" })
    }

    @Test func rejectsUnsafeNames() async throws {
        let env = try await TestEnvironment.make()
        defer { env.cleanup() }
        await #expect(throws: TaxonomyError.self) { try await env.folder("A/B", area: "Home") }
    }
}
