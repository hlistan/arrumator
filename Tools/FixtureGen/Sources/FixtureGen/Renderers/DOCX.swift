import AppKit

/// Word document written by AppKit's Office Open XML exporter, then re-zipped for reproducible bytes.
struct DOCXRenderer {
    let settings: RenderSettings

    func render(_ document: Document) throws -> Data {
        let text = TextLayout(settings: settings, bodySize: settings.typography.bodySize, target: .docx)
            .attributedString(for: document)
        let created = DateTimeStamp(document.info.created, hour: settings.pdf.metadataHour, minute: 0, second: 0).date
        let raw = try text.data(from: NSRange(location: 0, length: text.length), documentAttributes: [
            .documentType: NSAttributedString.DocumentType.officeOpenXML,
            .title: document.info.title,
            .author: document.info.author,
            .subject: document.info.subject,
            .creationTime: created,
            .modificationTime: created,
        ])
        return try ZipArchive(settings: settings).normalize(raw)
    }
}
