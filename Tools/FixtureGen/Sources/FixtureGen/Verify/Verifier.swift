import Foundation
import PDFKit

/// `fixturegen --verify`: checks that every fixture listed in expected.json exists and says what the manifest
/// claims (text layers, identifiers, OCR legibility, encryption, duplicates) and that regeneration is
/// byte-for-byte reproducible.
struct Verifier {
    let settings: RenderSettings
    let root: URL

    private struct Outcome {
        let subject: String
        var failures: [String] = []
        var notes: [String] = []
    }

    func run() async throws -> Bool {
        let manifestURL = root.appending(path: Manifest.fileName)
        let manifest = try Manifest.decoder.decode(Manifest.self, from: Data(contentsOf: manifestURL))
        print("Verifying \(manifest.fixtures.count) fixtures in \(root.path)")
        var outcomes = [selfCheck(seed: manifest.seed)]
        report(outcomes[0])
        var totalBytes = 0
        for record in manifest.fixtures {
            let outcome = try await verify(record)
            totalBytes += (try? Data(contentsOf: root.appending(path: record.file)).count) ?? 0
            report(outcome)
            outcomes.append(outcome)
        }
        let determinism = try verifyDeterminism(manifest)
        report(determinism)
        outcomes.append(determinism)
        let failed = outcomes.filter { !$0.failures.isEmpty }.count
        let size = ByteCountFormatter.string(fromByteCount: Int64(totalBytes), countStyle: .file)
        print("\(outcomes.count) checks, \(failed) failed · corpus size \(size)")
        return failed == 0
    }

    private func report(_ outcome: Outcome) {
        let status = outcome.failures.isEmpty ? "ok  " : "FAIL"
        let detail = (outcome.failures + outcome.notes).joined(separator: " · ")
        print("  \(status)  \(outcome.subject.padding(toLength: 44, withPad: " ", startingAt: 0)) \(detail)")
    }

    // MARK: Checksum sanity

    private func selfCheck(seed: UInt64) -> Outcome {
        var outcome = Outcome(subject: "checksums")
        let canonical = IBAN.compact(Fake.canonicalIBAN)
        let nib = String(canonical.dropFirst(4))
        let cast = Cast(seed: seed)
        let checks: [(String, Bool)] = [
            ("NIF \(Fake.canonicalNIF) valid", Checksum.isValidPTNIF(Fake.canonicalNIF)),
            ("NIF \(Fake.invalidNIF) invalid", !Checksum.isValidPTNIF(Fake.invalidNIF)),
            ("canonical IBAN mod-97", Checksum.isValidIBAN(Fake.canonicalIBAN)),
            ("canonical NIB check digits", 98 - Checksum.mod97(String(nib.prefix(19)) + "00") == Int(nib.suffix(2))),
            ("ИНН 7707083893 valid", Checksum.isValidRUINN("7707083893")),
            ("Russian account key matches its БИК", Checksum.isValidRUAccount(cast.ivanAccount, bik: cast.sberbankBIK)),
            ("generated IBANs valid", [cast.joao.iban, cast.alexWiseIBAN].allSatisfy(Checksum.isValidIBAN)),
        ]
        for (name, passed) in checks where !passed {
            outcome.failures.append(name)
        }
        if outcome.failures.isEmpty {
            outcome.notes.append("canonical NIF/IBAN valid, invalid NIF rejected, ИНН/account/IBAN algorithms consistent")
        }
        return outcome
    }

    // MARK: Per-fixture checks

    private func verify(_ record: FixtureRecord) async throws -> Outcome {
        var outcome = Outcome(subject: record.file)
        let url = root.appending(path: record.file)
        guard let data = try? Data(contentsOf: url), !data.isEmpty else {
            outcome.failures.append("missing or empty")
            return outcome
        }
        if let original = record.duplicateOf {
            let originalData = try? Data(contentsOf: root.appending(path: original))
            if originalData == data {
                outcome.notes.append("byte-identical to \(original)")
            } else {
                outcome.failures.append("not byte-identical to \(original)")
            }
            return outcome
        }
        let warnings = Set(record.expected.warnings ?? [])
        switch record.kind {
        case .pdfText where warnings.contains(.encrypted):
            checkEncrypted(url, password: record.password, into: &outcome)
        case .pdfText where warnings.contains(.corrupted):
            checkCorrupt(url, into: &outcome)
        case .pdfText:
            checkTextLayer(TextProbe.pdfText(at: url) ?? "", record, into: &outcome)
        case .docx:
            checkTextLayer(try TextProbe.docxText(at: url), record, into: &outcome)
        case .xlsx:
            checkTextLayer(try TextProbe.xlsxText(at: url), record, into: &outcome)
        case .eml:
            checkEmail(String(decoding: data, as: UTF8.self), record, into: &outcome)
        case .text:
            checkTextFile(data, record, into: &outcome)
        case .pdfScan:
            let layer = (TextProbe.pdfText(at: url) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !layer.isEmpty {
                outcome.failures.append("scan has a text layer (\(layer.count) characters)")
            }
            let pages = ImageProbe.pages(ofPDFAt: url, dpi: settings.verification.ocrDPI)
            guard !pages.isEmpty else {
                outcome.failures.append("PDF has no renderable pages")
                return outcome
            }
            var text = ""
            for page in pages {
                text += try await OCREngine().recognize(page, primary: record.lang) + "\n"
            }
            outcome.notes.append("no text layer, \(pages.count) page\(pages.count == 1 ? "" : "s")")
            checkOCR(text, record, into: &outcome)
        case .imagePhoto, .imageScreenshot:
            guard let image = ImageProbe.image(at: url) else {
                outcome.failures.append("image cannot be decoded")
                return outcome
            }
            if record.kind == .imagePhoto {
                if let taken = ImageProbe.exifDateTimeOriginal(at: url) {
                    outcome.notes.append("EXIF \(taken)")
                } else {
                    outcome.failures.append("EXIF DateTimeOriginal missing")
                }
            }
            checkOCR(try await OCREngine().recognize(image, primary: record.lang), record, into: &outcome)
        }
        return outcome
    }

    /// Text-layer formats must contain every title word, every expected identifier and no unlisted
    /// checksum-valid NIF/ИНН; distractors must be present but invalid.
    private func checkTextLayer(_ text: String, _ record: FixtureRecord, into outcome: inout Outcome) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            outcome.failures.append("no extractable text")
            return
        }
        let words = record.expected.titleContains
        let missingWords = words.filter { !TextMatch.contains(text, $0) }
        if missingWords.isEmpty {
            outcome.notes.append("title words \(words.count)/\(words.count)")
        } else {
            outcome.failures.append("title words missing: \(missingWords.joined(separator: ", "))")
        }
        let compactText = TextMatch.compact(text)
        let expected = Set(record.expected.identifiers)
        let missingIdentifiers = expected.filter { !compactText.contains(TextMatch.compact(value(of: $0))) }
        if !missingIdentifiers.isEmpty {
            outcome.failures.append("identifiers missing: \(missingIdentifiers.sorted().joined(separator: ", "))")
        }
        let unlisted = Identifier.checksumValidTokens(in: text).subtracting(expected)
        if !unlisted.isEmpty {
            outcome.failures.append("unlisted checksum-valid numbers: \(unlisted.sorted().joined(separator: ", "))")
        }
        let distractors = record.invalidIdentifiers ?? []
        let absentDistractors = distractors.filter { !compactText.contains(TextMatch.compact(value(of: $0))) }
        if !absentDistractors.isEmpty {
            outcome.failures.append("distractors not in text: \(absentDistractors.joined(separator: ", "))")
        }
        outcome.notes.append("identifiers \(expected.count - missingIdentifiers.count)/\(expected.count)"
                             + (distractors.isEmpty ? "" : ", \(distractors.count) invalid distractor"))
    }

    private func checkOCR(_ text: String, _ record: FixtureRecord, into outcome: inout Outcome) {
        let words = record.expected.titleContains
        if words.isEmpty {
            let visible = text.filter { !$0.isWhitespace }.count
            if visible <= 3 {
                outcome.notes.append("OCR finds no text")
            } else {
                outcome.failures.append("blank page yields OCR text: \(text.prefix(40))")
            }
            return
        }
        let found = words.filter { TextMatch.contains(text, $0) }
        let coverage = Double(found.count) / Double(words.count)
        let summary = "OCR title words \(found.count)/\(words.count) (\(Int((coverage * 100).rounded()))%)"
        if coverage >= settings.verification.minimumTitleCoverage {
            outcome.notes.append(summary)
        } else {
            outcome.failures.append(summary + ", missing \(words.filter { !found.contains($0) }.joined(separator: ", "))")
        }
        let identifiers = record.expected.identifiers
        if !identifiers.isEmpty {
            let compactText = TextMatch.compact(text)
            let recovered = identifiers.filter { compactText.contains(TextMatch.compact(value(of: $0))) }.count
            outcome.notes.append("OCR identifiers \(recovered)/\(identifiers.count)")
        }
    }

    private func checkEncrypted(_ url: URL, password: String?, into outcome: inout Outcome) {
        guard let document = PDFDocument(url: url) else {
            outcome.failures.append("encrypted PDF does not open at all")
            return
        }
        guard document.isEncrypted, document.isLocked else {
            outcome.failures.append("PDF is not locked")
            return
        }
        if document.unlock(withPassword: "") {
            outcome.failures.append("empty password unlocks the PDF")
        } else if let password, document.unlock(withPassword: password), !(document.string ?? "").isEmpty {
            outcome.notes.append("locked; opens with the recorded password")
        } else {
            outcome.failures.append("recorded password does not unlock the PDF")
        }
    }

    private func checkCorrupt(_ url: URL, into outcome: inout Outcome) {
        let text = (PDFDocument(url: url)?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty {
            outcome.notes.append("unreadable by PDFKit")
        } else {
            outcome.failures.append("truncated PDF still yields \(text.count) characters")
        }
    }

    private func checkEmail(_ raw: String, _ record: FixtureRecord, into outcome: inout Outcome) {
        let required = ["From: ", "Subject: =?UTF-8?B?", "Content-Type: multipart/mixed", "Content-Type: text/plain; charset=UTF-8",
                        "Content-Transfer-Encoding: quoted-printable", "Content-Disposition: attachment", "\r\n"]
        let missing = required.filter { !raw.contains($0) }
        if !missing.isEmpty {
            outcome.failures.append("MIME structure incomplete: \(missing.map { $0.debugDescription }.joined(separator: ", "))")
        }
        checkTextLayer(raw, record, into: &outcome)
    }

    private func checkTextFile(_ data: Data, _ record: FixtureRecord, into outcome: inout Outcome) {
        guard let encoding = record.encoding else {
            outcome.failures.append("text fixture without an encoding")
            return
        }
        guard let text = String(data: data, encoding: encoding.stringEncoding) else {
            outcome.failures.append("does not decode as \(encoding.rawValue)")
            return
        }
        if encoding != .utf8 {
            if String(data: data, encoding: .utf8) == nil {
                outcome.notes.append("\(encoding.rawValue), not valid UTF-8")
            } else {
                outcome.failures.append("\(encoding.rawValue) file also decodes as UTF-8, so it does not test detection")
            }
        }
        checkTextLayer(text, record, into: &outcome)
    }

    private func value(of token: String) -> String {
        String(token.split(separator: ":", maxSplits: 1).last ?? "")
    }

    // MARK: Determinism

    private func verifyDeterminism(_ manifest: Manifest) throws -> Outcome {
        var outcome = Outcome(subject: "determinism (seed \(manifest.seed))")
        let scratch = FileManager.default.temporaryDirectory.appending(path: "fixturegen-verify-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: scratch) }
        _ = try Generator(settings: settings, seed: manifest.seed).generate(into: scratch)
        let committedManifest = try Data(contentsOf: root.appending(path: Manifest.fileName))
        if committedManifest != (try Data(contentsOf: scratch.appending(path: Manifest.fileName))) {
            outcome.failures.append("\(Manifest.fileName) differs from a fresh render")
        }
        var identical = 0
        var skipped: [String] = []
        for fixture in Catalog.fixtures(seed: manifest.seed) {
            let file = fixture.record.file
            guard fixture.isByteDeterministic else {
                skipped.append((file as NSString).lastPathComponent)
                continue
            }
            let committed = try? Data(contentsOf: root.appending(path: file))
            let fresh = try Data(contentsOf: scratch.appending(path: file))
            if committed == fresh {
                identical += 1
            } else {
                outcome.failures.append("\(file) differs")
            }
        }
        outcome.notes.append("\(identical) files byte-identical after re-rendering")
        if !skipped.isEmpty {
            outcome.notes.append("skipped (random encryption salt): \(skipped.joined(separator: ", "))")
        }
        return outcome
    }
}
