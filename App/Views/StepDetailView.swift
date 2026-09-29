import ArrumatorCore
import SwiftUI

/// What is worth knowing about one funnel step. The statistics that used to sit in a separate screen live here
/// instead, each under the step it describes, so a number always has a place in the story.
struct StepDetail: View {
    @Environment(AppModel.self) private var model
    let step: FunnelStepStats
    let insights: Insights?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(step.title).font(.headline)
            Text(step.detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            timing
            if !step.stoppedHere.isEmpty { stops }
            specific
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(.quaternary.opacity(0.3), in: .rect(cornerRadius: 10))
    }

    private var timing: some View {
        HStack(spacing: 18) {
            figure("Reached", "\(step.reached)")
            figure("Went on", "\(step.passed)")
            if step.medianMs > 0 { figure("Typical file", Format.duration(step.medianMs)) }
            if step.p95Ms > 0 { figure("Slowest one in twenty", Format.duration(step.p95Ms)) }
            if step.errors > 0 { figure("Failed here", "\(step.errors)") }
            Spacer()
        }
    }

    private var stops: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Stopped here").font(.subheadline.weight(.medium))
            ForEach(step.stoppedHere) { stop in
                HStack(spacing: 6) {
                    Text("\(stop.count)").monospacedDigit().frame(width: 40, alignment: .trailing)
                    Text(stop.reason)
                    if stop.reason.contains("Waiting for you") {
                        Button("Open Needs You") { model.go(.review) }.buttonStyle(.link)
                    }
                    Spacer()
                }
                .font(.callout)
            }
        }
    }

    /// The numbers that belong to this particular step and nowhere else.
    @ViewBuilder private var specific: some View {
        if let insights {
            switch step.id {
            case "read": readingQuality(insights)
            case "analysed": labelling(insights)
            case "filed": corrections(insights)
            case "learned": senders
            default: EmptyView()
            }
        }
    }

    // MARK: Read

    @ViewBuilder private func readingQuality(_ insights: Insights) -> some View {
        Divider()
        if let ocr = insights.meanOCRConfidence {
            figure("How clearly scans read", Format.percent(ocr))
        }
        if insights.warnings.isEmpty {
            Text("No trouble reading any file.").font(.callout).foregroundStyle(.secondary)
        } else {
            Text("Trouble reading files").font(.subheadline.weight(.medium))
            ForEach(insights.warnings.sorted { $0.value > $1.value }, id: \.key) { code, count in
                HStack {
                    Text("\(count)").monospacedDigit().frame(width: 40, alignment: .trailing)
                    Text(Self.warningText(code))
                    Spacer()
                }
                .font(.callout)
            }
        }
    }

    // MARK: Analysed

    @ViewBuilder private func labelling(_ insights: Insights) -> some View {
        Divider()
        HStack(spacing: 18) {
            figure("Labelled", "\(insights.labelled)")
            figure("Not labelled yet", "\(insights.unlabelled)")
            Spacer()
        }
        if !insights.labelsByKind.isEmpty {
            HStack(spacing: 18) {
                ForEach(LabelKind.allCases, id: \.self) { kind in
                    figure(Wording.labelKind(kind), "\(insights.labelsByKind[kind.rawValue] ?? 0)")
                }
                Spacer()
            }
        }
    }

    // MARK: Filed

    @ViewBuilder private func corrections(_ insights: Insights) -> some View {
        Divider()
        HStack(spacing: 18) {
            figure("Corrected by you", "\(insights.corrected)")
            figure("Confirmed by you", "\(insights.confirmed)")
            Spacer()
        }
    }

    // MARK: Learned

    @ViewBuilder private var senders: some View {
        Divider()
        Button("Open Senders") { model.go(.senders) }.buttonStyle(.link)
    }

    // MARK: Pieces

    private func figure(_ name: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(name).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title3.monospacedDigit())
        }
    }

    static func warningText(_ code: String) -> String {
        switch code {
        case "encrypted": "Locked with a password"
        case "corrupted": "Damaged file"
        case "unsupported": "Format it cannot read"
        case "tooLarge": "Too large to read fully"
        case "ocrLowConfidence": "Scan was hard to read"
        case "toolFailed": "A converter failed"
        case "encodingGuessed": "Text encoding had to be guessed"
        case "vlmFailed": "Could not describe the image"
        default: code
        }
    }
}
