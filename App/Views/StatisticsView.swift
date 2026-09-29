import ArrumatorCore
import SwiftUI

/// Everything about how the pipeline is doing, organised as the path a file takes. Each step carries the statistics
/// that belong to it, so a number always has a place in the story.
///
/// Deliberately bars sharing one baseline rather than a tapered funnel: a funnel encodes values as the width of a
/// trapezoid, so early losses look larger than late ones and the filled areas mean nothing.
struct StatisticsView: View {
    @Environment(AppModel.self) private var model
    @State private var funnel: ProcessingFunnel?
    @State private var insights: Insights?
    @State private var days = 30
    @State private var selected: String?

    private var windows: [Int] { model.runtime?.config.stats.windowsDays ?? [7, 30, 90] }
    private var minimumForShares: Int { model.runtime?.config.stats.funnel.minimumForShares ?? 20 }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let funnel {
                    if funnel.documents == 0 {
                        ContentUnavailableView("Nothing has come through yet", systemImage: "chart.bar",
                                               description: Text("Statistics appear once files have been filed."))
                            .frame(maxWidth: .infinity).padding(.vertical, 40)
                    } else {
                        verdict(funnel)
                        FunnelSteps(funnel: funnel, selected: $selected,
                                    showsShares: funnel.showsShares(minimum: minimumForShares))
                        if let selected, let step = funnel.steps.first(where: { $0.id == selected }) {
                            StepDetail(step: step, insights: insights)
                        }
                        EndedUp(steps: funnel.steps, documents: funnel.documents)
                    }
                } else {
                    ProgressView().frame(maxWidth: .infinity).padding(40)
                }
            }
            .padding(16)
        }
        .safeAreaInset(edge: .top) { header }
        .task(id: "\(days)|\(model.activity)") {
            funnel = await model.load("Load statistics") { try await $0.stats.funnel(days: days) }
            insights = await model.load("Load statistics") { try await $0.stats.insights() }
        }
    }

    private var header: some View {
        HStack {
            Text("Statistics").font(.title3.bold())
            Spacer()
            Picker("Period", selection: $days) {
                ForEach(windows, id: \.self) { Text("Last \($0) days").tag($0) }
            }
            .labelsHidden().frame(width: 150)
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
        .background(.bar)
    }

    /// One sentence in plain words, so the screen can be read without decoding a chart.
    private func verdict(_ funnel: ProcessingFunnel) -> some View {
        var parts: [String] = ["\(funnel.documents) files arrived in the last \(funnel.windowDays) days."]
        if let drop = funnel.biggestDropOff, let worst = drop.stoppedHere.first {
            parts.append("Most that did not get filed stopped at \(drop.title.lowercased()): \(worst.count) \(worst.reason.lowercased()).")
        } else {
            parts.append("Every one of them was filed.")
        }
        if let slow = funnel.slowestStep {
            parts.append("\(slow.title) is the slowest step, \(Format.duration(slow.medianMs)) for a typical file.")
        }
        return Text(parts.joined(separator: " "))
            .font(.callout).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// The funnel: one row per step, each with a bar on a shared scale.
private struct FunnelSteps: View {
    let funnel: ProcessingFunnel
    @Binding var selected: String?
    let showsShares: Bool

    private static let barWidth: CGFloat = 220

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(funnel.steps.enumerated()), id: \.element.id) { index, step in
                Button {
                    selected = selected == step.id ? nil : step.id
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: selected == step.id ? "chevron.down" : "chevron.right")
                            .font(.caption2).foregroundStyle(.secondary).frame(width: 10)
                        Text(step.title).frame(width: 230, alignment: .leading).lineLimit(1)
                        bar(step)
                        cell("\(step.reached)", width: 55)
                        cell(step.dropped > 0 ? "\(step.dropped)" : "—", width: 60,
                             colour: step.dropped > 0 ? .primary : .secondary)
                        cell(showsShares ? Format.percent(step.cumulativeShare) : "—", width: 80)
                        cell(step.medianMs > 0 ? Format.duration(step.medianMs) : "—", width: 70)
                        cell(step.p95Ms > 0 ? Format.duration(step.p95Ms) : "—", width: 70)
                        HStack(spacing: 6) {
                            if step.errors > 0 { Label("\(step.errors)", systemImage: "xmark.octagon.fill").foregroundStyle(.red) }
                            if step.warnings > 0 { Label("\(step.warnings)", systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
                        }
                        .font(.caption)
                        Spacer(minLength: 0)
                    }
                    .font(.callout)
                    .padding(.vertical, 7).padding(.horizontal, 10)
                    .background(selected == step.id ? AnyShapeStyle(.selection.opacity(0.25)) : AnyShapeStyle(.clear))
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                if index < funnel.steps.count - 1 { Divider() }
            }
        }
        .background(.quaternary.opacity(0.3), in: .rect(cornerRadius: 10))
        .safeAreaInset(edge: .top, spacing: 0) {
            HStack(spacing: 10) {
                Color.clear.frame(width: 10)
                Text("Step").frame(width: 230, alignment: .leading)
                Text("How far files got").frame(width: Self.barWidth, alignment: .leading)
                cell("Reached", width: 55)
                cell("Stopped", width: 60)
                cell("Of all", width: 80)
                cell("Typical", width: 70)
                cell("Slowest", width: 70)
                Spacer(minLength: 0)
            }
            .font(.caption).foregroundStyle(.secondary)
            .padding(.vertical, 5).padding(.horizontal, 10)
        }
    }

    /// Drawn rather than charted: the scale is shared across rows and the bar has to be visible at row height.
    private func bar(_ step: FunnelStepStats) -> some View {
        let widest = max(1, funnel.documents)
        let passed = Self.barWidth * CGFloat(step.passed) / CGFloat(widest)
        let dropped = Self.barWidth * CGFloat(max(0, step.dropped)) / CGFloat(widest)
        return ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 4).fill(Palette.track).frame(width: Self.barWidth, height: 12)
            HStack(spacing: 0) {
                Rectangle().fill(Palette.progress).frame(width: passed)
                Rectangle().fill(Self.stopColour(step)).frame(width: dropped)
            }
            .frame(height: 12)
            .clipShape(.rect(cornerRadius: 4))
        }
        .frame(width: Self.barWidth, alignment: .leading)
    }

    /// Red is kept for things that actually went wrong; a duplicate leaving early is the pipeline working.
    private static func stopColour(_ step: FunnelStepStats) -> Color {
        if step.stoppedHere.contains(where: { $0.severity == .problem }) { return Palette.problem }
        if step.stoppedHere.contains(where: { $0.severity == .attention }) { return Palette.attention }
        return Palette.expected
    }

    private func cell(_ text: String, width: CGFloat, colour: Color = .primary) -> some View {
        Text(text).monospacedDigit().foregroundStyle(colour).frame(width: width, alignment: .trailing).lineLimit(1)
    }
}

/// Where everything ended up, as one bar: constant height means each file takes the same area wherever it is.
private struct EndedUp: View {
    let steps: [FunnelStepStats]
    let documents: Int

    private struct Slice: Identifiable {
        let id: String
        let count: Int
        let colour: Color
    }

    private var slices: [Slice] {
        var totals: [String: (count: Int, severity: FunnelSeverity)] = [:]
        for step in steps {
            for stop in step.stoppedHere {
                totals[stop.reason] = ((totals[stop.reason]?.count ?? 0) + stop.count, stop.severity)
            }
        }
        let stopped = totals.values.reduce(0) { $0 + $1.count }
        var all = totals.map { Slice(id: $0.key, count: $0.value.count, colour: Self.colour($0.value.severity)) }
            .sorted { $0.count > $1.count }
        all.insert(Slice(id: "Filed", count: max(0, documents - stopped), colour: Palette.progress), at: 0)
        return all.filter { $0.count > 0 }
    }

    private static func colour(_ severity: FunnelSeverity) -> Color {
        switch severity {
        case .expected: Palette.expected
        case .attention: Palette.attention
        case .problem: Palette.problem
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Where files ended up").font(.headline)
            GeometryReader { geo in
                HStack(spacing: 1) {
                    ForEach(slices) { slice in
                        Rectangle().fill(slice.colour)
                            .frame(width: max(2, geo.size.width * CGFloat(slice.count) / CGFloat(max(1, documents))))
                    }
                    Spacer(minLength: 0)
                }
                .clipShape(.rect(cornerRadius: 4))
            }
            .frame(height: 18)
            ForEach(slices) { slice in
                HStack(spacing: 8) {
                    RoundedRectangle(cornerRadius: 2).fill(slice.colour).frame(width: 9, height: 9)
                    Text(slice.id).lineLimit(1)
                    Spacer()
                    Text("\(slice.count)").monospacedDigit().foregroundStyle(.secondary)
                }
                .font(.callout)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(.quaternary.opacity(0.3), in: .rect(cornerRadius: 10))
    }
}
