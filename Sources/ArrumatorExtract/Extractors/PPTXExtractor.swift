import ArrumatorCore
import Foundation
import UniformTypeIdentifiers

/// PowerPoint decks: `<a:t>` runs of `ppt/slides/slideN.xml` in slide order (up to `pptxMaxSlides`), then the
/// speaker notes, plus core properties.
struct PPTXExtractor: FileExtractor {
    let name = "pptx"
    let version = 1
    var supportedTypes: [UTType] {
        [UTType("org.openxmlformats.presentationml.presentation")].compactMap { $0 }
    }

    func extract(_ job: ExtractionJob) async throws -> ExtractionDraft {
        let config = job.config
        let zip: ZipReader
        do {
            zip = try ZipReader(url: job.url, entryCap: config.zipEntryCapBytes)
        } catch {
            return .metadataOnly(kind: .presentation, warnings: [ExtractionWarning(.corrupted, error.description)])
        }
        let paths = zip.entries.map(\.path)
        let slides = Self.numbered(paths, prefix: "ppt/slides/slide")
        let notes = Dictionary(Self.numbered(paths, prefix: "ppt/notesSlides/notesSlide").map { ($0.number, $0.path) },
                               uniquingKeysWith: { first, _ in first })
        var sections: [String] = []
        var noteSections: [String] = []
        var warnings: [ExtractionWarning] = []
        for slide in slides.prefix(config.pptxMaxSlides) {
            try Task.checkCancellation()
            do {
                if let text = try Self.text(zip, slide.path), !text.isEmpty {
                    sections.append("Slide \(slide.number)\n\(text)")
                }
                if let notesPath = notes[slide.number], let text = try Self.text(zip, notesPath), !text.isEmpty {
                    noteSections.append("Notes \(slide.number)\n\(text)")
                }
            } catch {
                warnings.append(ExtractionWarning(.corrupted, "slide \(slide.number): \(error)"))
            }
        }
        if slides.count > config.pptxMaxSlides {
            warnings.append(ExtractionWarning(.textTruncated, "first \(config.pptxMaxSlides) of \(slides.count) slides"))
        }
        let text = (sections + noteSections).joined(separator: "\n\n")
        var draft = ExtractionDraft(kind: .presentation, textOrigin: text.isEmpty ? .none : .textLayer, text: text)
        draft.structure = ContentStructure(paragraphCount: TextNormalizer.nonEmptyLineCount(text), slideCount: slides.count)
        draft.metadata = OOXMLCoreProperties.metadata(of: job.url, entryCap: config.zipEntryCapBytes, prefix: "doc")
        draft.warnings = warnings
        return draft
    }

    /// Entries named `<prefix><N>.xml`, sorted by N.
    private static func numbered(_ paths: [String], prefix: String) -> [(number: Int, path: String)] {
        paths.compactMap { path -> (Int, String)? in
            guard path.hasPrefix(prefix), path.hasSuffix(".xml"),
                  let number = Int(path.dropFirst(prefix.count).dropLast(".xml".count)) else { return nil }
            return (number, path)
        }
        .sorted { $0.0 < $1.0 }
    }

    private static func text(_ zip: ZipReader, _ path: String) throws -> String? {
        guard let data = try zip.data(at: path) else { return nil }
        return XMLTextCollector.paragraphs(data, runElement: "a:t", paragraphElement: "a:p").joined(separator: "\n")
    }
}
