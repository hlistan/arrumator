@testable import ArrumatorCore
import ArrumatorTesting
import Foundation
import Testing

/// What the index keeps as JSON is the value or nothing, never a stand-in for it, and an excerpt of a text is at most as
/// long as asked, however short.
@Suite struct StoredJSONTests {
    /// A value JSON cannot hold: a number that is not finite.
    struct Reading: Codable {
        var confidence: Double
    }

    @Test func aValueJSONCannotHoldIsAnErrorNotNull() throws {
        #expect(throws: JSONError.notEncodable("Reading", "")) {
            do { _ = try JSON.string(Reading(confidence: .nan)) } catch let JSONError.notEncodable(type, _) {
                throw JSONError.notEncodable(type, "")
            }
        }
        #expect(try JSON.string(Reading(confidence: 0.5)) == #"{"confidence":0.5}"#, "a value it can hold is written as before")
    }

    @Test func aStepWhoseOutputJSONCannotHoldSaysSoRatherThanRecordingNull() async throws {
        let sink = MemoryTraceSink()
        let trace = TraceContext(traceID: 1, sink: sink)
        await trace.record(.analyse, startedAt: TestTime.start, input: ["model": "m"], output: Reading(confidence: .infinity))
        let step = try #require(await sink.steps.first)
        #expect(step.output == nil && step.status == .warn && step.error?.contains("Reading") == true,
                "the output is left out, and why is the step's error: \(step.error ?? "")")
        #expect(step.input == #"{"model":"m"}"#, "what could be written is")
    }

    @Test func anExcerptIsAtMostAsLongAsAskedHoweverShort() throws {
        let source = SourceFile(path: "/x.txt", originalFilename: "x.txt", fileExtension: "txt", utType: "public.plain-text", byteSize: 0,
                                createdAt: nil, modifiedAt: nil, sha256: "x")
        let content = ExtractedContent(source: source, kind: .textDocument, textOrigin: .textLayer, text: "Fatura EDP de março, total 54,21 EUR",
                                       extractorName: "test")
        for limit in 0...6 {
            let excerpt = content.classificationExcerpt(maxChars: limit, tailDivisor: 2)
            #expect(excerpt.count <= limit, "an excerpt of at most \(limit) characters is no longer, and asking for it never traps: “\(excerpt)”")
        }
        #expect(content.classificationExcerpt(maxChars: 6, tailDivisor: 2) == "Fatura", "a limit too short for a head and a tail keeps the head")
    }
}
