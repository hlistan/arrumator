import ArrumatorCore
import SwiftUI

/// Every stage of how a document was processed: inputs, outputs, timings and the exact model exchange.
struct TraceView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let documentID: Int64
    /// The document's name, which the sheet is headed with.
    var name: String?
    @State private var traces: [TraceRecord] = []
    @State private var traceID: Int64?
    @State private var steps: [TraceStepRecord] = []
    /// The traces have been read, so an empty list means there are none.
    @State private var loaded = false

    var body: some View {
        VStack(alignment: .leading) {
            Text(Wording.howItWasRead(name)).font(.headline).lineLimit(1).truncationMode(.middle)
            HStack {
                Picker(Wording.run, selection: $traceID) {
                    ForEach(traces) { t in
                        Text(Wording.traceRun(t)).tag(Int64?.some(t.id ?? 0))
                    }
                }
                .frame(maxWidth: Style.traceRunPickerMaxWidth)
                Spacer()
                Button(Wording.done) { dismiss() }.keyboardShortcut(.cancelAction)
            }
            if loaded, traces.isEmpty {
                EmptyState(symbol: "list.bullet.rectangle", text: Wording.noTrace)
                Spacer()
            } else {
                steps(list: steps)
            }
        }
        .padding()
        .task {
            guard let read = await model.load(Wording.loadTracesAction, { try await $0.traces.traces(docID: documentID) }) else { return }
            traces = read
            traceID = traces.first?.id
            loaded = true
        }
        .task(id: traceID) {
            guard let traceID else { return }
            guard let loaded = await model.load(Wording.loadTraceAction, { try await $0.traces.trace(id: traceID) }) ?? nil else { return }
            steps = loaded.1
        }
    }

    private func steps(list steps: [TraceStepRecord]) -> some View {
        List(steps) { s in
            DisclosureGroup {
                if let e = s.error { Text(e).foregroundStyle(Palette.problem).textSelection(.enabled) }
                if let i = s.inputJson { payload(Wording.input, i) }
                if let o = s.outputJson { payload(Wording.output, o) }
            } label: {
                HStack {
                    Text(TraceStage(rawValue: s.stage).map(Wording.traceStage) ?? s.stage).bold()
                        .frame(width: Style.traceStageWidth, alignment: .leading)
                        .help(s.stage)
                    Text(s.status.rawValue).foregroundStyle(s.status.tint)
                    Spacer()
                    Text(Wording.milliseconds(Int(s.durationMs))).monospacedDigit().foregroundStyle(.secondary)
                }
            }
        }
    }

    private func payload(_ title: String, _ json: String) -> some View {
        VStack(alignment: .leading) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(pretty(json)).font(.caption.monospaced()).textSelection(.enabled)
        }
    }

    private func pretty(_ json: String) -> String {
        guard let value = JSON.decode(JSONValue.self, from: json) else { return json }
        return JSON.string(value, pretty: true)
    }
}
