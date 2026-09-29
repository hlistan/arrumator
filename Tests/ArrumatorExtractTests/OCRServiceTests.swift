import ArrumatorCore
@testable import ArrumatorExtract
import CoreGraphics
import Foundation
import ImageIO
import Testing

/// Stands in for Vision: answers from a script per device and records which device each recognition asked for.
private actor ScriptedRecognizer: TextRecognizing {
    enum Outcome: Sendable {
        case text(String)
        case failure(any Error & Sendable)
    }

    private let outcomes: [OCRDevice: Outcome]
    private(set) var devices: [OCRDevice] = []

    init(_ outcomes: [OCRDevice: Outcome]) { self.outcomes = outcomes }

    nonisolated func documentsSupport(_ languages: [String]) -> Bool { true }

    func recognize(_ image: CGImage, orientation: CGImagePropertyOrientation, engine: OCREngine, languages: [String],
                   on device: OCRDevice) async throws -> RecognizedText {
        devices.append(device)
        switch outcomes[device] {
        case let .text(text):
            return RecognizedText(text: text, paragraphs: [text], tables: [],
                                  lines: [RecognizedLine(text: text, confidence: 0.9)], languages: languages)
        case let .failure(error):
            throw error
        case nil:
            Issue.record("no outcome scripted for \(device)")
            throw CancellationError()
        }
    }
}

/// What Vision throws when its Neural Engine model fails to compile (`CRImageReaderError`, E5RT error 13).
private struct AcceleratedPathFailed: Error {}
private struct CPUFailed: Error {}

@Suite("OCR falls back to the CPU when Vision's default device fails")
struct OCRServiceTests {
    private let request = OCRRequest(languages: ["pt"], lowConfidenceLine: 0.5, orientationRetryBelow: nil)

    private func page() throws -> CGImage { try Scratch.textImage(["Fatura"], width: 400, height: 200) }

    @Test func aPageReadOnTheDefaultDeviceIsNotAskedAgain() async throws {
        let vision = ScriptedRecognizer([.automatic: .text("Fatura")])
        let result = try await OCRService(recognizer: vision).recognize(try page(), request: request)
        #expect(result.text == "Fatura")
        #expect(result.device == .automatic, "the Neural Engine or GPU is used wherever it works")
        #expect(await vision.devices == [.automatic], "a page that was read is not read a second time")
    }

    @Test func aPageTheDefaultDeviceCannotReadIsReadOnTheCPU() async throws {
        let vision = ScriptedRecognizer([.automatic: .failure(AcceleratedPathFailed()), .cpu: .text("Fatura")])
        let result = try await OCRService(recognizer: vision).recognize(try page(), request: request)
        #expect(result.text == "Fatura", "a Mac whose accelerated path fails still gets its scans read")
        #expect(result.device == .cpu, "the trace says which device read the page")
        #expect(await vision.devices == [.automatic, .cpu])
    }

    @Test func onceTheCPUWasNeededLaterPagesGoStraightToIt() async throws {
        let vision = ScriptedRecognizer([.automatic: .failure(AcceleratedPathFailed()), .cpu: .text("Fatura")])
        let service = OCRService(recognizer: vision)
        _ = try await service.recognize(try page(), request: request)
        let second = try await service.recognize(try page(), request: request)
        #expect(second.device == .cpu)
        #expect(await vision.devices == [.automatic, .cpu, .cpu],
                "the failing path keeps failing until the process restarts, so it is not tried for every page")
    }

    @Test func aPageNeitherDeviceCanReadFailsWithTheCPUError() async throws {
        let vision = ScriptedRecognizer([.automatic: .failure(AcceleratedPathFailed()), .cpu: .failure(CPUFailed())])
        await #expect(throws: CPUFailed.self, "the last error is the one reported as the page's OCR warning") {
            try await OCRService(recognizer: vision).recognize(try page(), request: request)
        }
        #expect(await vision.devices == [.automatic, .cpu])
    }

    @Test func cancellationIsNotRetried() async throws {
        let vision = ScriptedRecognizer([.automatic: .failure(CancellationError())])
        await #expect(throws: CancellationError.self, "stopping a job stops its OCR, on no device") {
            try await OCRService(recognizer: vision).recognize(try page(), request: request)
        }
        #expect(await vision.devices == [.automatic])
    }

    @Test(.enabled(VisionOCR.unavailable) { await VisionOCR.available.value })
    func visionReadsTextWithEveryStageOnTheCPU() async throws {
        let image = try Scratch.textImage(["Fatura de eletricidade"], width: 1200, height: 300, fontSize: 60)
        let found = try await VisionTextRecognizer().recognize(image, orientation: .up, engine: .recognizeText,
                                                               languages: ["pt"], on: .cpu)
        #expect(found.text.contains("eletricidade"), "the fallback device reads text on its own: \(found.text)")
    }

    @Test func thePageTraceRecordsTheDevice() async throws {
        let vision = ScriptedRecognizer([.automatic: .failure(AcceleratedPathFailed()), .cpu: .text("Fatura")])
        var pass = OCRPass(service: OCRService(recognizer: vision), config: try TestConfig.pipeline().extraction)
        _ = try await pass.recognize(try page(), page: 1, languages: ["pt"], timeout: 30, orientationRetryBelow: nil)
        #expect(pass.pages.map(\.device) == ["cpu"], "How was this decided? shows the page was read on the CPU")
        #expect(pass.warnings.isEmpty, "a page the CPU read is no failure")
    }
}
