import ArrumatorCore
import ArrumatorTesting
import Foundation
import Testing

/// The folder tree takes whatever shape the logic describes: any depth, folders named as the logic names them.
@Suite struct TaxonomyStoreTests {
    private let bank = ["Portugal", "Hlistan Zolerani LDA", "Banking", "Santander"]

    @Test func archiveStartsEmptyAndSystemFoldersAppearOnlyWhenNeeded() async throws {
        let env = try await TestEnvironment.make()
        defer { env.cleanup() }
        #expect(try await env.taxonomy.snapshot(root: env.archive).folders.isEmpty)
        let review = try await env.taxonomy.ensureSystemFolder(.needsReview, root: env.archive)
        #expect(review.role == .needsReview && !review.acceptsFiles && !review.holdsUserDocuments)
        let again = try await env.taxonomy.ensureSystemFolder(.needsReview, root: env.archive)
        #expect(again.id == review.id)
        let snapshot = try await env.taxonomy.snapshot(root: env.archive)
        #expect(snapshot.folder(role: .duplicates) == nil)
        #expect(review.relativePath == "System/Needs review", "system folders are named, not numbered")
        #expect(snapshot.topLevel.isEmpty, "the system area is not one of the user's folders")
        #expect(FileManager.default.fileExists(atPath: snapshot.url(for: review).appendingPathComponent(env.config.taxonomy.aboutFileName).path))
    }

    @Test func foldersAreCreatedAsDeepAsThePathGoesAndNamedOnly() async throws {
        let env = try await TestEnvironment.make()
        defer { env.cleanup() }
        let santander = try await env.folder(path: bank, yearly: true)
        let snapshot = try await env.taxonomy.snapshot(root: env.archive)
        #expect(santander.relativePath == bank.joined(separator: "/"))
        #expect(snapshot.lineage(of: santander).map(\.name) == bank)
        #expect(snapshot.depth(of: santander) == 4)
        #expect(snapshot.lineage(of: santander).map(\.code) == ["F1", "F2", "F3", "F4"], "codes are the app's, not part of names")
        #expect(santander.yearSubfolders && !(snapshot.folder(code: "F3")?.yearSubfolders ?? true), "only the last level is by year")
        #expect(snapshot.lineage(of: santander).allSatisfy { $0.acceptsFiles && $0.origin == .learned })
        for folder in snapshot.lineage(of: santander) {
            #expect(FileManager.default.fileExists(atPath: snapshot.url(for: folder).appendingPathComponent(env.config.taxonomy.aboutFileName).path))
        }
        let index = try String(contentsOf: env.archive.appendingPathComponent(env.config.taxonomy.indexFileName), encoding: .utf8)
        #expect(index.contains("      - **Santander**"), "the index lists the tree at every depth")
    }

    @Test func existingLevelsAreReusedAndOnlyTheRestCreated() async throws {
        let env = try await TestEnvironment.make()
        defer { env.cleanup() }
        let santander = try await env.folder(path: bank)
        let millennium = try await env.folder(path: Array(bank.dropLast()) + ["Millennium"])
        let snapshot = try await env.taxonomy.snapshot(root: env.archive)
        #expect(millennium.parentCode == santander.parentCode)
        #expect(snapshot.folders.count == 5)
        #expect(snapshot.children(of: santander.parentCode).map(\.name).sorted() == ["Millennium", "Santander"])
    }

    @Test func aPathDeeperThanTheArchiveAllowsCreatesNothing() async throws {
        let env = try await TestEnvironment.make()
        defer { env.cleanup() }
        let tooDeep = (1...(env.config.taxonomy.maxDepth + 1)).map { "Level \($0)" }
        await #expect(throws: TaxonomyError.self) { try await env.folder(path: tooDeep) }
        #expect(try await env.taxonomy.snapshot(root: env.archive).folders.isEmpty, "no half-made path is left behind")
    }

    @Test func aRemovedFolderCodeIsNeverUsedAgain() async throws {
        let env = try await TestEnvironment.make()
        defer { env.cleanup() }
        let gone = try await env.folder("Old Bills", area: "Home")
        _ = try await env.taxonomy.pruneEmpty(root: env.archive, folderIDs: [gone.id])
        let next = try await env.folder("Utilities", area: "Home")
        #expect(next.code != gone.code && next.parentCode != gone.parentCode, "the emptied area went too, and neither code returns")
    }

    @Test func userEditsSurviveAndRenamesAreFollowed() async throws {
        let env = try await TestEnvironment.make()
        defer { env.cleanup() }
        let folder = try await env.folder(path: bank)
        var snapshot = try await env.taxonomy.snapshot(root: env.archive)
        let dir = snapshot.url(for: folder)
        let aboutURL = dir.appendingPathComponent(env.config.taxonomy.aboutFileName)
        try Data((try String(contentsOf: aboutURL, encoding: .utf8) + "\nPersonal note.\n").utf8).write(to: aboutURL)
        try await env.taxonomy.updateLearned(folderID: folder.id, root: env.archive,
                                             learned: LearnedBlock(examples: ["2026-07-05 Santander - Extrato.pdf"], correspondents: ["Santander"]))
        let text = try String(contentsOf: aboutURL, encoding: .utf8)
        #expect(text.contains("Personal note.") && text.contains("2026-07-05 Santander - Extrato.pdf"))
        let renamed = dir.deletingLastPathComponent().appendingPathComponent("Santander Totta")
        try FileManager.default.moveItem(at: dir, to: renamed)
        let changes = try await env.taxonomy.sync(root: env.archive)
        #expect(changes.contains { $0.kind == .renamed && $0.code == folder.code })
        snapshot = try await env.taxonomy.snapshot(root: env.archive)
        let found = try #require(snapshot.folder(code: folder.code))
        #expect(found.name == "Santander Totta" && found.id == folder.id && found.learnedCorrespondents == ["Santander"])
    }

    @Test func foldersFromEarlierVersionsKeepTheirCodesAndReadAsTheirNames() async throws {
        let env = try await TestEnvironment.make()
        defer { env.cleanup() }
        let area = env.archive.appendingPathComponent("10-19 Home", isDirectory: true)
        let category = area.appendingPathComponent("11 Utilities", isDirectory: true)
        try FileManager.default.createDirectory(at: category, withIntermediateDirectories: true)
        for (dir, code, name) in [(area, "10-19", "Home"), (category, "11", "Utilities")] {
            let about = AboutFile(definition: FolderDefinition(code: code, name: name, description: "\(name) documents.",
                                                               yearSubfolders: false, yearRule: nil, autoFile: true, origin: .learned),
                                  body: "")
            try Data(try about.render(hash: .recompute).utf8).write(to: dir.appendingPathComponent(env.config.taxonomy.aboutFileName))
        }
        _ = try await env.taxonomy.sync(root: env.archive)
        let snapshot = try await env.taxonomy.snapshot(root: env.archive)
        let utilities = try #require(snapshot.folder(code: "11"))
        #expect(snapshot.path(of: utilities) == "Home / Utilities" && utilities.parentCode == "10-19")
        #expect(utilities.relativePath == "10-19 Home/11 Utilities", "the directories on disk are left as they are")
        let beside = try await env.folder("Water", area: "Home")
        #expect(beside.parentCode == "10-19" && beside.relativePath == "10-19 Home/Water", "a new folder joins it, named only")
    }

    @Test func foldersTheUserMakesAreFoldersAtAnyDepth() async throws {
        let env = try await TestEnvironment.make()
        defer { env.cleanup() }
        let banking = try await env.folder(path: Array(bank.dropLast()))
        let snapshot = try await env.taxonomy.snapshot(root: env.archive)
        let seeds = snapshot.url(for: banking).appendingPathComponent("Revolut/Savings", isDirectory: true)
        try FileManager.default.createDirectory(at: seeds, withIntermediateDirectories: true)
        let changes = try await env.taxonomy.sync(root: env.archive)
        #expect(changes.filter { $0.kind == .inferred }.count == 2)
        var tree = try await env.taxonomy.snapshot(root: env.archive)
        let savings = try #require(tree.folders.first { $0.name == "Savings" })
        #expect(tree.path(of: savings) == (Array(bank.dropLast()) + ["Revolut", "Savings"]).joined(separator: " / "))
        #expect(savings.holdsUserDocuments && !savings.acceptsFiles, "the app files into it once it is described")
        try FileManager.default.moveItem(at: seeds, to: seeds.deletingLastPathComponent().appendingPathComponent("Deposits"))
        _ = try await env.taxonomy.sync(root: env.archive)
        tree = try await env.taxonomy.snapshot(root: env.archive)
        #expect(tree.folder(code: savings.code)?.name == "Deposits", "a renamed folder of the user's is still the same folder")
    }

    @Test func yearFoldersAndExcludedDirectoriesAreNotFolders() async throws {
        let env = try await TestEnvironment.make()
        defer { env.cleanup() }
        let santander = try await env.folder(path: bank, yearly: true)
        let snapshot = try await env.taxonomy.snapshot(root: env.archive)
        try FileManager.default.createDirectory(at: snapshot.url(for: santander).appendingPathComponent("2025"), withIntermediateDirectories: true)
        let inbox = env.archive.appendingPathComponent("Inbox/Scans", isDirectory: true)
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        await env.taxonomy.exclude([env.archive.appendingPathComponent("Inbox")])
        _ = try await env.taxonomy.sync(root: env.archive)
        let names = try await env.taxonomy.snapshot(root: env.archive).folders.map(\.name)
        #expect(!names.contains("2025") && !names.contains("Inbox") && !names.contains("Scans"))
    }

    @Test func aFolderNeverTakesOverTheAppsOwnOrAnExcludedDirectory() async throws {
        let env = try await TestEnvironment.make()
        defer { env.cleanup() }
        let about = env.config.taxonomy.aboutFileName
        let review = try await env.taxonomy.ensureSystemFolder(.needsReview, root: env.archive)
        let areaCode = try #require(review.parentCode)
        let area = try #require(try await env.taxonomy.snapshot(root: env.archive).folder(code: areaCode))
        let areaAbout = env.archive.appendingPathComponent(area.relativePath).appendingPathComponent(about)
        let before = try String(contentsOf: areaAbout, encoding: .utf8)
        await #expect(throws: TaxonomyError.self) { try await env.folder(path: [area.name, "Scans"]) }
        #expect(try String(contentsOf: areaAbout, encoding: .utf8) == before, "the system area keeps its description")
        #expect(try await env.taxonomy.snapshot(root: env.archive).topLevel.isEmpty)

        let incoming = env.archive.appendingPathComponent("Incoming", isDirectory: true)
        try FileManager.default.createDirectory(at: incoming, withIntermediateDirectories: true)
        await env.taxonomy.exclude([incoming])
        await #expect(throws: TaxonomyError.self) { try await env.folder(path: ["Incoming"]) }
        #expect(!FileManager.default.fileExists(atPath: incoming.appendingPathComponent(about).path), "Incoming is not made a folder")
    }

    @Test func whatAFolderStandsForIsKeptInItsAboutFileAndReadBackFromTheArchive() async throws {
        let env = try await TestEnvironment.make()
        defer { env.cleanup() }
        let edp = try await env.folder(path: ["Portugal", "EDP"], kinds: [.topic, .sender], logic: "abc123")
        var snapshot = try await env.taxonomy.snapshot(root: env.archive)
        let about = try String(contentsOf: snapshot.url(for: edp).appendingPathComponent(env.config.taxonomy.aboutFileName), encoding: .utf8)
        #expect(about.contains("kind: sender") && about.contains("logic: abc123"))
        let mine = try await env.taxonomy.createFolder(root: env.archive, parentCode: nil, name: "Mine", description: "Mine.",
                                                       yearSubfolders: false, yearRule: nil, origin: .user)
        #expect(mine.kind == nil && mine.logic == nil, "a folder the user makes stands for nothing the logic said")

        let documents = DocumentStore(database: env.database)
        let learning = GRDBLearningStore(database: env.database)
        let filedFrom = try await learning.saveCorrespondent(Correspondent(canonicalName: "EDP", origin: .learned)).id
        let waitingFrom = try await learning.saveCorrespondent(Correspondent(canonicalName: "MEO", origin: .learned)).id
        for (status, sender) in [(DocumentStatus.filed, filedFrom), (.needsReview, waitingFrom)] {
            var record = DocumentRecord.arrived(path: "/tmp/\(sender).pdf", sha256: "\(sender)", size: 1, uttype: "com.adobe.pdf",
                                                inode: nil, modified: nil)
            record.folderId = edp.id
            record.status = status
            record.correspondentId = sender
            _ = try await documents.save(record)
        }
        snapshot = try await env.taxonomy.snapshot(root: env.archive)
        #expect(snapshot.folder(code: edp.code)?.senders == [filedFrom], "a folder's senders are those of the documents filed in it")

        let fresh = TaxonomyStore(database: try AppDatabase.inMemory(), config: env.config.taxonomy, registry: nil)
        _ = try await fresh.sync(root: env.archive)
        let reread = try await fresh.snapshot(root: env.archive)
        #expect(reread.folder(code: edp.code)?.kind == .sender && reread.folder(code: edp.code)?.logic == "abc123")
        #expect(reread.folder(code: try #require(edp.parentCode))?.kind == .topic, "a lost index learns it again from the archive")
    }

    @Test func namesAreUniqueWithinTheirFolder() async throws {
        let env = try await TestEnvironment.make()
        defer { env.cleanup() }
        let first = try await env.folder("Taxes (Portugal)", area: "Money")
        let again = try await env.folder("taxes (portugal)", area: "money")
        #expect(again.id == first.id)
        let elsewhere = try await env.folder("Taxes (Portugal)", area: "Home")
        #expect(elsewhere.id != first.id, "logic may give a topic a home in another folder")
        let lower = try await env.folder("medical records", area: "health")
        #expect(lower.name == "Medical records")
        #expect(try await env.taxonomy.snapshot(root: env.archive).topLevel.map(\.name).sorted() == ["Health", "Home", "Money"])
    }

    @Test func rejectsNamesThatCannotBeFolders() async throws {
        let env = try await TestEnvironment.make()
        defer { env.cleanup() }
        await #expect(throws: TaxonomyError.self) { try await env.folder("A/B", area: "Home") }
        await #expect(throws: TaxonomyError.self, "a year is a year folder, not a folder") { try await env.folder("2025", area: "Home") }
    }
}
