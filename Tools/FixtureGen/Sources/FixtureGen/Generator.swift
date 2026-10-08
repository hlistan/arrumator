import Foundation

/// Renders every fixture and writes expected.json, with the pairs of labels the model is to judge.
struct Generator {
    let settings: RenderSettings
    let seed: UInt64

    struct Summary {
        let fileCount: Int
        let totalBytes: Int
    }

    /// Replaces the generated folders and expected.json under `root`; other files (README.md) are left alone.
    func generate(into root: URL) throws -> Summary {
        let fileManager = FileManager.default
        for folder in Catalog.folders {
            let url = root.appending(path: folder)
            if fileManager.fileExists(atPath: url.path) {
                try fileManager.removeItem(at: url)
            }
            try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        }
        let fixtures = Catalog.fixtures(seed: seed)
        var produced: [String: Data] = [:]
        for fixture in fixtures {
            if let text = fixture.ocrSourceText {
                let unlisted = Identifier.checksumValidTokens(in: text).subtracting(fixture.record.expected.identifiers)
                precondition(unlisted.isEmpty, "\(fixture.record.file) prints checksum-valid numbers missing from its identifiers: \(unlisted.sorted())")
            }
            let data = try render(fixture, produced: produced)
            produced[fixture.record.file] = data
            try data.write(to: root.appending(path: fixture.record.file))
        }
        let manifest = Manifest(schema: Manifest.currentSchema, baselineVersion: Manifest.baselineVersion, seed: seed,
                                fixtures: fixtures.map(\.record), labelPairs: LabelPairs.all)
        let json = manifest.data
        try json.write(to: root.appending(path: Manifest.fileName))
        return Summary(fileCount: fixtures.count, totalBytes: produced.values.reduce(json.count) { $0 + $1.count })
    }

    private func render(_ fixture: Fixture, produced: [String: Data]) throws -> Data {
        let file = fixture.record.file
        var fake = Fake(seed: seed, salt: "render:" + file)
        switch fixture.payload {
        case .pdfText(let document):
            return PDFTextRenderer(settings: settings).render(document, key: file)
        case .pdfScan(let source):
            return PDFScanRenderer(settings: settings).render(source, key: file, fake: &fake)
        case .docx(let document):
            return try DOCXRenderer(settings: settings).render(document)
        case .xlsx(let workbook):
            return try XLSXRenderer(settings: settings).render(workbook)
        case .screenshot(let screen):
            return ScreenshotRenderer(settings: settings).render(screen)
        case .photo(let photo):
            return PhotoRenderer(settings: settings).render(photo, fake: &fake)
        case .email(let email):
            return EMLRenderer().render(email)
        case .text(let text, let encoding):
            return try TextNoteRenderer().render(text, encoding: encoding)
        case .copy(let original):
            guard let data = produced[original] else {
                preconditionFailure("\(file) copies \(original), which must be generated first")
            }
            return data
        case .encryptedPDF(let document, let password):
            return PDFTextRenderer(settings: settings).render(document, key: file, password: password)
        case .truncatedPDF(let document):
            let whole = PDFTextRenderer(settings: settings).render(document, key: file)
            return whole.prefix(Int(Double(whole.count) * settings.pdf.truncatedFraction))
        }
    }
}
