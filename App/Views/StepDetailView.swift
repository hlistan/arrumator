import ArrumatorCore
import SwiftUI

/// What is worth knowing about one funnel step. The statistics that used to sit in a separate screen live here
/// instead, each under the step it describes, so a number always has a place in the story.
struct StepDetail: View {
    @Environment(AppModel.self) private var model
    let step: FunnelStepStats
    let insights: Insights?

    var body: some View {
        VStack(alignment: .leading, spacing: Style.stepDetailSpacing) {
            Text(step.title).font(.headline)
            Text(step.detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            timing
            if !step.stoppedHere.isEmpty { stops }
            specific
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Style.statsPanelPadding)
        .background(.quaternary.opacity(Style.statsPanelFillOpacity), in: .rect(cornerRadius: Style.statsPanelCornerRadius))
    }

    private var timing: some View {
        HStack(spacing: Style.figureSpacing) {
            figure(Wording.reached, "\(step.reached)")
            figure(Wording.wentOn, "\(step.passed)")
            if step.medianMs > 0 { figure(Wording.typicalFile, Format.duration(step.medianMs)) }
            if step.p95Ms > 0 { figure(Wording.slowestOneInTwenty, Format.duration(step.p95Ms)) }
            if step.errors > 0 { figure(Wording.failedHere, "\(step.errors)") }
            Spacer()
        }
    }

    private var stops: some View {
        VStack(alignment: .leading, spacing: Style.stepStopsSpacing) {
            Text(Wording.stoppedHere).font(.subheadline.weight(.medium))
            ForEach(step.stoppedHere) { stop in
                HStack(spacing: Style.stepStopSpacing) {
                    Text("\(stop.count)").monospacedDigit().frame(width: Style.stepCountWidth, alignment: .trailing)
                    Text(stop.reason)
                    if stop.status == .needsReview {
                        Button(Wording.openNeedsYou) { model.go(.review) }.buttonStyle(.link)
                    }
                    Spacer()
                }
                .font(.callout)
            }
        }
    }

    /// The numbers that belong to this particular step and nowhere else.
    @ViewBuilder private var specific: some View {
        // Which step a statistic belongs to follows from the stages it covers, however `stats.funnel.steps` names it.
        if let insights {
            if step.stages.contains(.extract) { readingQuality(insights) }
            if step.stages.contains(.analyse) { labelling(insights) }
            if step.stages.contains(.place) { corrections(insights) }
        }
    }

    // MARK: Read

    @ViewBuilder private func readingQuality(_ insights: Insights) -> some View {
        Divider()
        if let ocr = insights.meanOCRConfidence {
            figure(Wording.scanClarity, Format.percent(ocr))
        }
        if insights.warnings.isEmpty {
            Text(Wording.noReadingTrouble).font(.callout).foregroundStyle(.secondary)
        } else {
            Text(Wording.readingTrouble).font(.subheadline.weight(.medium))
            ForEach(insights.warnings.sorted { ($0.value, $1.key.rawValue) > ($1.value, $0.key.rawValue) }, id: \.key) { code, count in
                HStack {
                    Text("\(count)").monospacedDigit().frame(width: Style.stepCountWidth, alignment: .trailing)
                    Text(Wording.warning(code))
                    Spacer()
                }
                .font(.callout)
            }
        }
    }

    // MARK: Analysed

    @ViewBuilder private func labelling(_ insights: Insights) -> some View {
        Divider()
        HStack(spacing: Style.figureSpacing) {
            figure(Wording.labelledFigure, "\(insights.labelled)")
            figure(Wording.notLabelledYet, "\(insights.unlabelled)")
            figure(Wording.labelsTidied, "\(insights.labelsTidied)")
            figure(Wording.yourLabelRules, "\(insights.labelRules.values.reduce(0, +))")
            Spacer()
        }
        if !insights.labelsByKind.isEmpty {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: Style.figureMinWidth), alignment: .leading)], alignment: .leading) {
                ForEach(LabelKind.allCases.filter { insights.labelsByKind[$0.rawValue] != nil }, id: \.self) { kind in
                    figure(Wording.labelKind(kind), "\(insights.labelsByKind[kind.rawValue] ?? 0)")
                }
            }
        }
    }

    // MARK: Filed

    @ViewBuilder private func corrections(_ insights: Insights) -> some View {
        Divider()
        HStack(spacing: Style.figureSpacing) {
            figure(Wording.correctedByYou, "\(insights.corrected)")
            figure(Wording.confirmedByYou, "\(insights.confirmed)")
            Spacer()
        }
    }

    // MARK: Pieces

    private func figure(_ name: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: Style.figureLabelSpacing) {
            Text(name).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title3.monospacedDigit())
        }
    }
}
