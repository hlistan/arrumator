import ArrumatorCore
import Foundation
import UniformTypeIdentifiers

/// RFC 5322 messages (.eml): From/To/Cc/Subject/Date with RFC 2047 decoding, the first text/plain part that is no
/// attachment (else the first text/html part stripped to text) decoded from base64/quoted-printable and its charset,
/// and the names of every other part that has one, a message attached among them as one, by its name or its subject. A
/// message with no text of its own that forwards another is given the text of the one it forwards, marked as such. The
/// file is read up to `emailReadCapBytes` and the body kept up to `emailBodyCapBytes`, each cut noted.
/// Outlook `.msg` (OLE compound files) is reported metadata-only.
struct EmailExtractor: FileExtractor {
    /// The names an HTML body's character references may use.
    let entities: HTMLEntities

    let name = "email"
    let version = 4
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
        let read = read(message, job: job, forwardsLeft: config.emailForwardsRead, depthLeft: config.emailMaxPartDepth)
        if read.bodyTruncated {
            warnings.append(ExtractionWarning(.textTruncated, "body: first \(config.emailBodyCapBytes) bytes"))
        }

        var metadata: [String: String] = [:]
        for (header, key) in Self.addressHeaders {
            guard let value = message.decodedHeader(header), !value.isEmpty else { continue }
            metadata[MetadataKey.email(key)] = value
        }
        if let rawDate = message.header("Date") {
            metadata[MetadataKey.emailDate] = Self.parseDate(rawDate)?.date.formatted(.iso8601) ?? rawDate
        }
        if let id = message.header("Message-ID") { metadata[MetadataKey.emailMessageID] = id }

        let text = (read.headerLines + ["", read.body]).joined(separator: "\n")
        var draft = ExtractionDraft(kind: .email, textOrigin: .textLayer, text: text)
        draft.metadata = metadata
        draft.attachments = read.attachments
        draft.structure = ContentStructure(paragraphCount: TextNormalizer.nonEmptyLineCount(read.body))
        draft.warnings = warnings
        return draft
    }

    /// The headers a message's text begins with, and the metadata keys of those kept as metadata.
    private static let addressHeaders = [("From", "from"), ("To", "to"), ("Cc", "cc"), ("Subject", "subject")]

    /// What a message says: its header lines, the names of what is attached to it among them, and its body.
    private struct MessageText {
        var headerLines: [String] = []
        var attachments: [String] = []
        var body = ""
        var bodyTruncated = false
    }

    /// The text of `message`. Its body is its first text part that is not sent as an attachment; every other part
    /// with a name is listed, a message attached to it by its name or else its subject. A message whose body holds no
    /// text, as one that only forwards another as an attachment, is given the text of the first message attached to
    /// it, marked as such, `forwardsLeft` deep at most. A message read within it is parsed within the `depthLeft` levels of
    /// nesting the whole e-mail has (`emailMaxPartDepth`), so the bound is the e-mail's, not each message's.
    private func read(_ message: MIMEPart, job: ExtractionJob, forwardsLeft: Int, depthLeft: Int) -> MessageText {
        let config = job.config
        let leaves = message.leaves
        let bodyIndex = leaves.firstIndex { $0.mediaType == "text/plain" && !$0.isAttachment }
            ?? leaves.firstIndex { $0.mediaType == "text/html" && !$0.isAttachment }
        var text = MessageText()
        for (header, _) in Self.addressHeaders {
            guard let value = message.decodedHeader(header), !value.isEmpty else { continue }
            text.headerLines.append("\(header): \(value)")
        }
        if let rawDate = message.header("Date") { text.headerLines.append("Date: \(Self.parseDate(rawDate)?.day.iso ?? rawDate)") }
        if let bodyIndex {
            let part = leaves[bodyIndex]
            let decoded = part.decodedText(cap: config.emailBodyCapBytes)
            text.body = part.mediaType == "text/html" ? HTMLText.strip(decoded.text, entities: entities) : decoded.text
            text.bodyTruncated = decoded.truncated
        }
        let bodiless = text.body.allSatisfy(\.isWhitespace)
        var forwarded: MIMEPart?
        var names: [Int: String] = [:]
        for (index, leaf) in leaves.enumerated() where index != bodyIndex && leaf.isMessage {
            // An attached message is read only for what is asked of it: its text, when the message has none and may read
            // one more, and otherwise for its subject when it has no name, its parts then left unsplit. Its bytes are
            // decoded once either way, so the work stays linear in the file.
            let forwards = bodiless && forwarded == nil && forwardsLeft > 0 && depthLeft > 0
            guard forwards || leaf.filename == nil else { continue }
            let attached = leaf.attachedMessage(cap: config.emailReadCapBytes, maxDepth: forwards ? depthLeft - 1 : 0)
            if forwards { forwarded = attached }
            if leaf.filename == nil, let subject = attached?.decodedHeader("Subject") { names[index] = subject }
        }
        text.attachments = leaves.indices.filter { $0 != bodyIndex }.compactMap { names[$0] ?? leaves[$0].filename }.filter { !$0.isEmpty }
        if !text.attachments.isEmpty { text.headerLines.append("Attachments: " + text.attachments.joined(separator: ", ")) }
        if let forwarded {
            let inner = read(forwarded, job: job, forwardsLeft: forwardsLeft - 1, depthLeft: depthLeft - 1)
            text.body = ([Self.attachedMessageMark] + inner.headerLines + ["", inner.body]).joined(separator: "\n")
            text.bodyTruncated = inner.bodyTruncated
        }
        return text
    }

    /// The line that begins the text of a message attached to one that has none of its own.
    private static let attachedMessageMark = "Attached message:"

    /// RFC 5322 dates (`Tue, 1 Jul 2003 10:52:37 +0200`, with or without weekday/seconds, trailing comments): the moment
    /// they name, read with their zone, and the day as written, in the zone they are written in (§3.3), the day the
    /// sender's clock showed rather than the day it then was here. The day is read from the date with its zone left
    /// out, so it is the one written whatever the zone: an offset, `UT`, `Z`, `GMT+1` or `EST` (-0500 all year, §4.3).
    private static func parseDate(_ raw: String) -> (date: Date, day: CalendarDay)? {
        let cleaned = raw.replacingOccurrences(of: #"\s*\([^)]*\)\s*$"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        guard let zoneStart = cleaned.lastIndex(of: " ") else { return nil }
        let wallClock = String(cleaned[..<zoneStart])
        for format in dateFormats {
            guard let date = formatter(format + " Z").date(from: cleaned) ?? formatter(format + " zzz").date(from: cleaned),
                  let written = formatter(format).date(from: wallClock) else { continue }
            return (date, GregorianCalendar(timeZone: .gmt).day(of: written))
        }
        return nil
    }

    /// A formatter of RFC 5322 dates in `format`, which reads a date without a zone as UTC.
    private static func formatter(_ format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .gmt
        formatter.dateFormat = format
        return formatter
    }

    /// RFC 5322 §3.3 dates without their zone: with or without the day of the week and the seconds.
    private static let dateFormats = ["EEE, d MMM yyyy HH:mm:ss", "d MMM yyyy HH:mm:ss", "EEE, d MMM yyyy HH:mm", "d MMM yyyy HH:mm"]
}
