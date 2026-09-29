import Foundation

struct Mailbox: Sendable {
    let name: String
    let address: String
}

struct Attachment: Sendable {
    let filename: String
    let contentType: String
    let content: String
}

/// A received e-mail: multipart/mixed holding a text/plain + text/html alternative and one attachment.
struct Email: Sendable {
    let from: Mailbox
    let to: Mailbox
    let sent: DateTimeStamp
    let subject: String
    let messageID: String
    let plainBody: String
    let htmlBody: String
    let attachment: Attachment
}

/// Writes RFC 5322 / MIME with CRLF line endings. Non-ASCII headers use RFC 2047 encoded words; the plain
/// part is 8bit UTF-8, the HTML part quoted-printable and the attachment base64, so all three transfer
/// encodings are exercised.
struct EMLRenderer {
    private static let lineLimit = 76
    private static let encodedWordPayloadBytes = 45

    func render(_ email: Email) -> Data {
        let outer = "=_arrumator_fixture_mixed"
        let inner = "=_arrumator_fixture_alternative"
        var lines = [
            "Return-Path: <\(email.from.address)>",
            "MIME-Version: 1.0",
            "Date: \(email.sent.rfc5322)",
            "From: \(mailbox(email.from))",
            "To: \(mailbox(email.to))",
            "Message-ID: <\(email.messageID)>",
            "Subject: \(encodedWords(email.subject))",
            "Content-Type: multipart/mixed; boundary=\"\(outer)\"",
            "",
            "This is a multi-part message in MIME format.",
            "",
            "--\(outer)",
            "Content-Type: multipart/alternative; boundary=\"\(inner)\"",
            "",
            "--\(inner)",
            "Content-Type: text/plain; charset=UTF-8",
            "Content-Transfer-Encoding: 8bit",
            "",
        ]
        lines += email.plainBody.components(separatedBy: "\n")
        lines += [
            "",
            "--\(inner)",
            "Content-Type: text/html; charset=UTF-8",
            "Content-Transfer-Encoding: quoted-printable",
            "",
        ]
        lines += quotedPrintable(email.htmlBody)
        lines += [
            "",
            "--\(inner)--",
            "",
            "--\(outer)",
            "Content-Type: \(email.attachment.contentType); name=\"\(email.attachment.filename)\"",
            "Content-Disposition: attachment; filename=\"\(email.attachment.filename)\"",
            "Content-Transfer-Encoding: base64",
            "",
        ]
        lines += Data(email.attachment.content.utf8)
            .base64EncodedString(options: [.lineLength76Characters, .endLineWithLineFeed])
            .components(separatedBy: "\n")
        lines += ["", "--\(outer)--", ""]
        return Data(lines.joined(separator: "\r\n").utf8)
    }

    private func mailbox(_ box: Mailbox) -> String {
        let name = box.name.allSatisfy(\.isASCII) ? "\"\(box.name)\"" : encodedWords(box.name)
        return "\(name) <\(box.address)>"
    }

    /// RFC 2047 "B" encoded words, split on character boundaries and folded onto continuation lines.
    private func encodedWords(_ text: String) -> String {
        guard !text.allSatisfy(\.isASCII) else { return text }
        var words: [String] = []
        var chunk = ""
        for character in text {
            if (chunk + String(character)).utf8.count > EMLRenderer.encodedWordPayloadBytes {
                words.append(chunk)
                chunk = ""
            }
            chunk.append(character)
        }
        words.append(chunk)
        return words.map { "=?UTF-8?B?\(Data($0.utf8).base64EncodedString())?=" }.joined(separator: "\r\n ")
    }

    /// Quoted-printable (RFC 2045) with soft line breaks; returns the encoded lines.
    private func quotedPrintable(_ text: String) -> [String] {
        var output: [String] = []
        for sourceLine in text.components(separatedBy: "\n") {
            var line = ""
            let bytes = Array(sourceLine.utf8)
            for (index, byte) in bytes.enumerated() {
                let isLast = index == bytes.count - 1
                let literal = (byte >= 33 && byte <= 126 && byte != UInt8(ascii: "=")) || (byte == 0x20 && !isLast)
                let token = literal ? String(UnicodeScalar(byte)) : String(format: "=%02X", byte)
                if line.count + token.count > EMLRenderer.lineLimit - 1 {
                    output.append(line + "=")
                    line = ""
                }
                line += token
            }
            output.append(line)
        }
        return output
    }
}
