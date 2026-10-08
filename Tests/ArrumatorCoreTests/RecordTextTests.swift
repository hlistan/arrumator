@testable import ArrumatorCore
import Foundation
import Testing

/// What the record files show people browsing the archive is in the time zone the runtime gives, not the process's.
@Suite struct RecordTextTests {
    @Test("A history's moments are written in the time zone given, with its offset", arguments: ["Asia/Tokyo", "America/Los_Angeles"])
    func historyInTheZoneGiven(zone: String) throws {
        let timeZone = try #require(TimeZone(identifier: zone))
        let event = try JSON.decoder.decode(EventEntry.self, from: Data("""
            {"id": 1, "at": "2026-07-15T23:30:00Z", "kind": "filed", "actor": "system", "summary": "Fatura", "payload": "{}"}
            """.utf8))
        let text = RecordText.history([event], month: "2026-07", in: timeZone)
        let written = event.at.formatted(Date.ISO8601FormatStyle(timeZone: timeZone).year().month().day()
            .time(includingFractionalSeconds: false).timeZone(separator: .colon))
        #expect(text.contains("- \(written) · filed · Fatura"), "on a Mac in \(zone), the moment as its clock showed it: \(text)")
        #expect(written.hasPrefix(zone == "Asia/Tokyo" ? "2026-07-16T08:30:00+09:00" : "2026-07-15T16:30:00-07:00"), "\(written)")
    }

    @Test func nothingInASidecarBecomesActiveWhereItsMarkdownIsShown() throws {
        let said = #"A bill. ![x](http://203.0.113.9/p.png) <img src="http://203.0.113.9/q.png"> [pay](http://example.com) \ end; "#
            + "pay at https://pay.example.com or WWW.example.com, write to bills@example.com"
        let text = "Total 10 €\n```\nshell\n```` four\n<script>x</script>"
        let sidecar = RecordText.sidecar(file: "[a] <b>.pdf", interpretation: said, imageDescription: "A sign: ![x](http://203.0.113.9/r.png)",
                                         text: text)
        #expect(sidecar.contains("# \\[a\\] \\<b\\>.pdf\n"), "the name's brackets and angles are escaped: \(sidecar)")
        let escaped = #"A bill. !\[x\](http\://203.0.113.9/p.png) \<img src="http\://203.0.113.9/q.png"\> \[pay\](http\://example.com) \\ end; "#
            + #"pay at https\://pay.example.com or WWW\.example.com, write to bills@example.com"#
        #expect(sidecar.contains(escaped),
                "what the model wrote makes no image, HTML or link, an address written alone none either, and shows as written: \(sidecar)")
        let attributed = try AttributedString(markdown: sidecar, options: .init(interpretedSyntax: .full))
        let links = attributed.runs.compactMap { run in run.link.map { ($0.absoluteString, String(attributed[run.range].characters)) } }
        #expect(!attributed.runs.contains { $0.imageURL != nil } && links.map(\.0) == ["mailto:bills@example.com"]
                    && links.allSatisfy { $0.0 == "mailto:" + $0.1 },
                "read as Markdown, nothing in it loads or hides where it goes: no image, and no link but an e-mail address shown as written: \(links)")
        #expect(sidecar.contains("`````text\n" + text + "\n`````\n"),
                "the text is code in a fence longer than any run of backticks it holds, so it ends where the text does")
        #expect(sidecar.contains("## What it shows\n\nA sign: !\\[x\\](http\\://203.0.113.9/r.png)\n"),
                "what the vision model saw in an image is escaped as the interpretation is: \(sidecar)")
        let plain = RecordText.sidecar(file: "a.pdf", interpretation: nil, imageDescription: nil, text: "")
        #expect(plain.contains("_No text was recognised in it._") && !plain.contains("## What it shows"),
                "and a document without text says so, one that is no image described having no part for it")
    }

    /// The model's words that would open a fence, and the text whose own fence of the same character would close it,
    /// each character on its own, so neither case passes for the other's escaping.
    static let fences: [(interpretation: String, imageDescription: String?, fence: String)] = [
        ("```Fatura da EDP.", nil, "```"), ("~~~ Fatura", nil, "~~~"), ("A bill.", "```A receipt", "```"), ("A bill.", "~~~A receipt", "~~~"),
    ]

    @Test(arguments: fences.indices)
    func neitherTheModelsWordsNorTheTextOpenOrCloseWhatTheOtherIsShownIn(case index: Int) throws {
        let (interpretation, imageDescription, fence) = Self.fences[index]
        let text = "Total 10 €\n\(fence)\n![x](http://203.0.113.9/p.png) <img src=\"http://203.0.113.9/q.png\">"
        let sidecar = RecordText.sidecar(file: "a.pdf", interpretation: interpretation, imageDescription: imageDescription, text: text)
        let attributed = try AttributedString(markdown: sidecar, options: .init(interpretedSyntax: .full))
        #expect(!attributed.runs.contains { $0.imageURL != nil || $0.link != nil },
                "a fence the model's words would open never lets the text's own fence close it, leaving the rest Markdown: \(sidecar)")
    }
}
