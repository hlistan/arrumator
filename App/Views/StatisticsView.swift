import ArrumatorCore
import SwiftUI

/// Everything about how the pipeline is doing, organised as the path a file takes. Each step carries the statistics
/// that belong to it, so a number always has a place in the story.
///
/// Deliberately bars sharing one baseline rather than a tapered funnel: a funnel encodes values as the width of a
/// trapezoid, so early losses look larger than late ones and the filled areas mean nothing.
struct StatisticsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let config = model.runtime?.config.stats {
            StatisticsPage(config: config)
        } else {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// Statistics over the periods `stats.windowsDays` offers, `stats.defaultWindowDays` first.
private struct StatisticsPage: View {
    @Environment(AppModel.self) private var model
    let config: StatsConfig
    @State private var funnel: ProcessingFunnel?
    @State private var insights: Insights?
    @State private var chosenDays: Int?
    @State private var selected: String?

    private var days: Int { chosenDays ?? config.defaultWindowDays }
    private var windows: [Int] { config.windowsDays.all }
    private var minimumForShares: Int { config.funnel.minimumForShares }

    var body: some View {
        Page(.statistics, notes: funnel.map(verdict)) {
            Picker(Wording.period, selection: Binding(get: { days }, set: { chosenDays = $0 })) {
                ForEach(windows, id: \.self) { Text(Wording.lastDays($0)).tag($0) }
            }
            .labelsHidden().fixedSize()
            if let funnel {
                if funnel.documents == 0 {
                    EmptyState(symbol: Destination.statistics.symbol,
                               text: funnel.waiting > 0 ? Wording.noneTakenYet(waiting: funnel.waiting) : Wording.statisticsAppear)
                } else {
                    FunnelSteps(funnel: funnel, selected: $selected,
                                showsShares: funnel.showsShares(minimum: minimumForShares))
                    if let selected, let step = funnel.steps.first(where: { $0.id == selected }) {
                        StepDetail(step: step, insights: insights)
                    }
                    EndedUp(outcomes: funnel.outcomes, documents: funnel.documents)
                }
            } else {
                ProgressView().frame(maxWidth: .infinity).padding(Style.statsPlaceholderPadding)
            }
        }
        .task(id: "\(days)|\(model.activity)") {
            let days = days
            if let read = await model.load(Wording.loadStatisticsAction, { try await $0.stats.funnel(days: days) }) { funnel = read }
            if let read = await model.load(Wording.loadStatisticsAction, { try await $0.stats.insights() }) { insights = read }
        }
    }

    /// A few sentences in plain words, so the page can be read without decoding a chart.
    private func verdict(_ funnel: ProcessingFunnel) -> String {
        guard funnel.documents > 0 else { return "" }
        var parts = [Wording.arrivedIn(funnel.documents, waiting: funnel.waiting, days: funnel.windowDays)]
        if funnel.inProgress > 0 { parts.append(Wording.stillBeingWorkedOn(funnel.inProgress)) }
        if let main = funnel.mainStop {
            parts.append(Wording.mostStopped(at: main.step.title, count: main.stop.count, reason: main.stop.reason))
        } else if funnel.inProgress == 0 {
            parts.append(Wording.everyOneFiled)
        }
        if let slow = funnel.slowestStep {
            parts.append(Wording.slowestStep(slow.title, duration: Format.duration(slow.medianMs)))
        }
        return parts.joined(separator: " ")
    }
}

/// The funnel: one row per step, each with a bar on a shared scale.
private struct FunnelSteps: View {
    let funnel: ProcessingFunnel
    @Binding var selected: String?
    let showsShares: Bool

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(funnel.steps.enumerated()), id: \.element.id) { index, step in
                Button {
                    selected = selected == step.id ? nil : step.id
                } label: {
                    HStack(spacing: Style.funnelColumnSpacing) {
                        Image(systemName: selected == step.id ? "chevron.down" : "chevron.right")
                            .font(.caption2).foregroundStyle(.secondary).frame(width: Style.funnelChevronWidth)
                        Text(step.title).frame(width: Style.funnelStepWidth, alignment: .leading).lineLimit(1)
                        bar(step)
                        cell("\(step.reached)", width: Style.funnelReachedWidth)
                        cell(step.dropped > 0 ? "\(step.dropped)" : Wording.noValue, width: Style.funnelStoppedWidth,
                             colour: step.dropped > 0 ? .primary : .secondary)
                        cell(showsShares ? Format.percent(step.cumulativeShare) : Wording.noValue, width: Style.funnelShareWidth)
                        cell(step.medianMs > 0 ? Format.duration(step.medianMs) : Wording.noValue, width: Style.funnelDurationWidth)
                        cell(step.p95Ms > 0 ? Format.duration(step.p95Ms) : Wording.noValue, width: Style.funnelDurationWidth)
                        HStack(spacing: Style.funnelProblemSpacing) {
                            if step.errors > 0 { Label("\(step.errors)", systemImage: "xmark.octagon.fill").foregroundStyle(Palette.problem) }
                            if step.warnings > 0 { Label("\(step.warnings)", systemImage: "exclamationmark.triangle").foregroundStyle(Palette.attention) }
                        }
                        .font(.caption)
                        Spacer(minLength: 0)
                    }
                    .font(.callout)
                    .padding(Style.funnelRowInsets)
                    .background(selected == step.id ? AnyShapeStyle(.selection.opacity(Style.funnelSelectionOpacity)) : AnyShapeStyle(.clear))
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                if index < funnel.steps.count - 1 { Divider() }
            }
        }
        .background(.quaternary.opacity(Style.statsPanelFillOpacity), in: .rect(cornerRadius: Style.statsPanelCornerRadius))
        .safeAreaInset(edge: .top, spacing: 0) {
            HStack(spacing: Style.funnelColumnSpacing) {
                Color.clear.frame(width: Style.funnelChevronWidth)
                Text(Wording.step).frame(width: Style.funnelStepWidth, alignment: .leading)
                Text(Wording.howFarFilesGot).frame(width: Style.funnelBarWidth, alignment: .leading)
                cell(Wording.reached, width: Style.funnelReachedWidth)
                cell(Wording.stopped, width: Style.funnelStoppedWidth)
                cell(Wording.ofAll, width: Style.funnelShareWidth)
                cell(Wording.typical, width: Style.funnelDurationWidth)
                cell(Wording.slowest, width: Style.funnelDurationWidth)
                Spacer(minLength: 0)
            }
            .font(.caption).foregroundStyle(.secondary)
            .padding(Style.funnelHeaderInsets)
        }
    }

    /// Drawn rather than charted: the scale is shared across rows and the bar has to be visible at row height.
    private func bar(_ step: FunnelStepStats) -> some View {
        let widest = max(1, funnel.documents)
        let passed = Style.funnelBarWidth * CGFloat(step.passed) / CGFloat(widest)
        let dropped = Style.funnelBarWidth * CGFloat(max(0, step.dropped)) / CGFloat(widest)
        return ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: Style.statsBarCornerRadius).fill(Palette.track).frame(width: Style.funnelBarWidth, height: Style.funnelBarHeight)
            HStack(spacing: 0) {
                Rectangle().fill(Palette.progress).frame(width: passed)
                Rectangle().fill(Self.stopColour(step)).frame(width: dropped)
            }
            .frame(height: Style.funnelBarHeight)
            .clipShape(.rect(cornerRadius: Style.statsBarCornerRadius))
        }
        .frame(width: Style.funnelBarWidth, alignment: .leading)
    }

    /// Red is kept for things that actually went wrong; a duplicate leaving early is the pipeline working.
    private static func stopColour(_ step: FunnelStepStats) -> Color {
        Palette.severity(step.stopSeverity ?? .expected)
    }

    private func cell(_ text: String, width: CGFloat, colour: Color = .primary) -> some View {
        Text(text).monospacedDigit().foregroundStyle(colour).frame(width: width, alignment: .trailing).lineLimit(1)
    }
}

/// Where everything ended up, as one bar: constant height means each file takes the same area wherever it is. Each
/// outcome once, as Core counts them (`ProcessingFunnel.outcomes`).
private struct EndedUp: View {
    let outcomes: [FunnelOutcome]
    let documents: Int

    private static func colour(_ outcome: FunnelOutcome) -> Color {
        outcome.isFiled ? Palette.progress : Palette.severity(outcome.severity)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Style.endedUpSpacing) {
            Text(Wording.whereFilesEndedUp).font(.headline)
            GeometryReader { geo in
                HStack(spacing: Style.sliceGap) {
                    ForEach(outcomes) { slice in
                        Rectangle().fill(Self.colour(slice))
                            .frame(width: max(Style.sliceMinWidth, geo.size.width * CGFloat(slice.count) / CGFloat(max(1, documents))))
                    }
                    Spacer(minLength: 0)
                }
                .clipShape(.rect(cornerRadius: Style.statsBarCornerRadius))
            }
            .frame(height: Style.endedUpBarHeight)
            .accessibilityHidden(true)
            ForEach(outcomes) { slice in
                HStack(spacing: Style.legendSpacing) {
                    RoundedRectangle(cornerRadius: Style.swatchCornerRadius).fill(Self.colour(slice))
                        .frame(width: Style.swatchSize.width, height: Style.swatchSize.height)
                    Text(slice.reason).lineLimit(1)
                    Spacer()
                    Text("\(slice.count)").monospacedDigit().foregroundStyle(.secondary)
                }
                .font(.callout)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Style.statsPanelPadding)
        .background(.quaternary.opacity(Style.statsPanelFillOpacity), in: .rect(cornerRadius: Style.statsPanelCornerRadius))
    }
}
