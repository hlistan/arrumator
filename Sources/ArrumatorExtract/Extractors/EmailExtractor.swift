import ArrumatorCore
import Foundation
import UniformTypeIdentifiers

/// RFC 5322 messages (.eml): From/To/Cc/Subject/Date with RFC 2047 decoding, the first text/plain part (else the
/// first text/html part stripped to text) decoded from base64/quoted-printable and its charset, and attachment
/// filenames. The file is read up to `emailReadCapBytes` and the body kept up to `emailBodyCapBytes`, each cut noted.
/// Outlook `.msg` (OLE compound files) is reported metadata-only.
struct EmailExtractor: FileExtractor {
    /// The names an HTML body's character references may use.
    let entities: HTMLEntities

    let name = "email"
    let version = 2
    var supportedTypes: [UTType] {
        [.emailMessage, UTType(filenameExtension: "eml"), Self.outlookMessage].compactMap { $0 }
    }

    private static let outlookMessage = UTType(filenameExtension: "msg")

    func extract(_ job: ExtractionJob) async throws -> ExtractionDraft {
        if let outlook = Self.outlookMessage, job.type == outlook {
            return .metadataOnly(kind: .email, warnings: [ExtractionWarning(.unsupportedFormat, "Outlook .msg")])
        }
        let config = job.config
        let (data, truncatedRead) = try job.head(upTo: config.emailReadCapBytes)
        let message = MIMEPart.parse(data, maxDepth: config.emailMaxPartDepth)
        guard message.header("From") != nil || message.header("Subject") != nil || message.header("Date") != nil else {
            return .metadataOnly(kind: .email, warnings: [ExtractionWarning(.corrupted, "no RFC 5322 headers")])
        }
        var warnings: [ExtractionWarning] = truncatedRead ? [.headRead(data.count, of: job.source.byteSize)] : []

        let leaves = message.leaves
        let bodyPart = leaves.first { $0.mediaType == "text/plain" && !$0.isAttachment }
            ?? leaves.first { $0.mediaType == "text/html" && !$0.isAttachment }
        let decoded = bodyPart.map { $0.decodedText(cap: config.emailBodyCapBytes) }
        var body = decoded?.text ?? ""
        if decoded?.truncated == true {
            warnings.append(ExtractionWarning(.textTruncated, "body: first \(config.emailBodyCapBytes) bytes"))
        }
        if bodyPart?.mediaType == "text/html" { body = HTMLText.strip(body, entities: entities) }
        let attachments = leaves.compactMap { $0.isAttachment ? $0.filename : nil }

        var metadata: [String: String] = [:]
        var headerLines: [String] = []
        for (header, key) in [("From", "from"), ("To", "to"), ("Cc", "cc"), ("Subject", "subject")] {
            guard let value = message.decodedHeader(header), !value.isEmpty else { continue }
            metadata[MetadataKey.email(key)] = value
            headerLines.append("\(header): \(value)")
        }
        if let rawDate = message.header("Date") {
            if let date = Self.parseDate(rawDate) {
                let iso = CalendarDay(date: date, calendar: .current).iso
                metadata[MetadataKey.emailDate] = date.formatted(.iso8601)
                headerLines.append("Date: \(iso)")
            } else {
                metadata[MetadataKey.emailDate] = rawDate
                headerLines.append("Date: \(rawDate)")
            }
        }
        if let id = message.header("Message-ID") { metadata[MetadataKey.emailMessageID] = id }
        if !attachments.isEmpty { headerLines.append("Attachments: " + attachments.joined(separator: ", ")) }

        let text = (headerLines + ["", body]).joined(separator: "\n")
        var draft = ExtractionDraft(kind: .email, textOrigin: .textLayer, text: text)
        draft.metadata = metadata
        draft.attachments = attachments
        draft.structure = ContentStructure(paragraphCount: TextNormalizer.nonEmptyLineCount(body))
        draft.warnings = warnings
        return draft
    }

    /// RFC 5322 dates (`Tue, 1 Jul 2003 10:52:37 +0200`, with or without weekday/seconds, trailing comments).
    static func parseDate(_ raw: String) -> Date? {
        let cleaned = raw.replacingOccurrences(of: #"\s*\([^)]*\)\s*$"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        for format in dateFormats {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = format
            if let date = formatter.date(from: cleaned) { return date }
        }
        return nil
    }

    private static let dateFormats = [
        "EEE, d MMM yyyy HH:mm:ss Z", "d MMM yyyy HH:mm:ss Z", "EEE, d MMM yyyy HH:mm Z", "d MMM yyyy HH:mm Z",
        "EEE, d MMM yyyy HH:mm:ss zzz", "d MMM yyyy HH:mm:ss zzz",
    ]
}
