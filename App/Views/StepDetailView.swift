import ArrumatorCore
import Charts
import SwiftUI

/// What is worth knowing about one funnel step. The statistics that used to sit in a separate screen live here
/// instead, each under the step it describes, so a number always has a place in the story.
struct StepDetail: View {
    @Environment(AppModel.self) private var model
    let step: FunnelStepStats
    let insights: Insights?
    let showsShares: Bool

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
            case "matched": whatItKnows(insights)
            case "decided": howSureItWas(insights)
            case "filed": whereItWentWrong(insights)
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

    // MARK: Matched

    @ViewBuilder private func whatItKnows(_ insights: Insights) -> some View {
        Divider()
        HStack(spacing: 18) {
            figure("Learned rules", "\(insights.rules)")
            figure("Times a rule was used", "\(insights.ruleHits)")
            figure("Times a rule was wrong", "\(insights.ruleContradictions)")
            if let knn = insights.meanKNNAgreement {
                figure("Past filings agreed", Format.percent(knn))
            }
            Spacer()
        }
        Button("Open Learned") { model.go(.learned) }.buttonStyle(.link)
        if !insights.overlaps.isEmpty {
            Text("Folders that look alike, which makes matching harder").font(.subheadline.weight(.medium))
            ForEach(insights.overlaps, id: \.self) { overlap in
                Text("\(Wording.path(ofCode: overlap.a, in: model.taxonomy)) and \(Wording.path(ofCode: overlap.b, in: model.taxonomy))")
                    .font(.callout)
            }
        }
    }

    // MARK: Decided

    @ViewBuilder private func howSureItWas(_ insights: Insights) -> some View {
        Divider()
        Text("How sure it was, and whether it was right").font(.subheadline.weight(.medium))
        ForEach(insights.bands, id: \.band) { band in
            HStack(spacing: 8) {
                Text(Self.bandText(band.band)).frame(width: 220, alignment: .leading)
                Text("\(band.total)").monospacedDigit().frame(width: 50, alignment: .trailing)
                Text(band.corrected > 0 ? "you moved \(band.corrected)" : "you moved none")
                    .foregroundStyle(.secondary).frame(width: 130, alignment: .leading)
                if showsShares, band.total > 0, band.band != Band.review.rawValue {
                    Text(Format.percent(1 - Double(band.corrected) / Double(band.total)) + " stayed put").monospacedDigit()
                }
                Spacer()
            }
            .font(.callout)
        }
        thresholdControl(insights)
        if !insights.accuracyByLanguage.isEmpty, showsShares {
            Text("By language: " + insights.accuracyByLanguage.sorted { $0.key < $1.key }
                .map { "\($0.key) \(Format.percent($0.value))" }.joined(separator: ", "))
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    /// The calibration curve made usable: move the line and see what it would have done.
    @ViewBuilder private func thresholdControl(_ insights: Insights) -> some View {
        let current = model.settings?.thresholds.auto ?? 0.85
        let nearest = insights.whatIf.min { abs($0.autoThreshold - current) < abs($1.autoThreshold - current) }
        VStack(alignment: .leading, spacing: 6) {
            Text("File automatically when the app is at least this sure").font(.subheadline.weight(.medium))
            HStack {
                Slider(value: setting(model, \.thresholds.auto, default: 0.85), in: 0.5...0.99)
                    .frame(maxWidth: 320)
                Text(String(format: "%.2f", current)).monospacedDigit().frame(width: 44)
            }
            if let nearest {
                Text("At this setting it would have filed \(Format.percent(nearest.autoShare)) on its own, and "
                     + "\(Format.percent(nearest.autoAccuracy)) of those stayed where it put them.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if insights.whatIf.contains(where: { $0.autoAccuracy != nil }) {
                Chart(insights.whatIf, id: \.autoThreshold) { point in
                    LineMark(x: .value("Sure at least", point.autoThreshold), y: .value("Filed on its own", point.autoShare))
                        .foregroundStyle(Palette.progress)
                    if let accuracy = point.autoAccuracy {
                        LineMark(x: .value("Sure at least", point.autoThreshold), y: .value("Stayed put", accuracy))
                            .foregroundStyle(.secondary)
                    }
                }
                .chartYScale(domain: 0...1)
                .chartYAxis { AxisMarks(format: Decimal.FormatStyle.Percent.percent.precision(.fractionLength(0))) }
                .chartLegend(.hidden)
                .frame(height: 110)
                Text("Solid line: how much it would file on its own. Grey line: how much of that stayed put.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Filed

    @ViewBuilder private func whereItWentWrong(_ insights: Insights) -> some View {
        Divider()
        if insights.confusion.isEmpty {
            Text("You have not moved anything it filed.").font(.callout).foregroundStyle(.secondary)
        } else {
            Text("Mix-ups you corrected").font(.subheadline.weight(.medium))
            ForEach(insights.confusion, id: \.self) { pair in
                HStack {
                    Text("\(pair.count)").monospacedDigit().frame(width: 40, alignment: .trailing)
                    Text("filed into \(Wording.path(ofCode: pair.from, in: model.taxonomy)), you moved to \(Wording.path(ofCode: pair.to, in: model.taxonomy))")
                    Spacer()
                }
                .font(.callout)
            }
            Text("Sharpen a folder's description from its page in the sidebar.").font(.callout).foregroundStyle(.secondary)
        }
        let busy = insights.folders.filter { $0.correctionsIn + $0.correctionsOut > 0 }
        if !busy.isEmpty {
            Text("Folders you correct most").font(.subheadline.weight(.medium))
            ForEach(busy.prefix(6), id: \.code) { folder in
                HStack {
                    Text(model.taxonomy?.path(ofCode: folder.code, separator: Wording.pathSeparator) ?? folder.name)
                    Spacer()
                    Text("\(folder.documents) filed · \(folder.correctionsIn) moved in · \(folder.correctionsOut) moved out")
                        .foregroundStyle(.secondary)
                }
                .font(.callout)
            }
        }
    }

    // MARK: Pieces

    private func figure(_ name: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(name).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title3.monospacedDigit())
        }
    }

    /// Bands are named, never shown as a bare number: a 0–1 score means nothing to a reader.
    static func bandText(_ band: String) -> String {
        switch Band(rawValue: band) {
        case .auto: "Filed without asking you"
        case .check: "Filed, but flagged for a glance"
        case .review: "Held for you to decide"
        case nil: band
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
