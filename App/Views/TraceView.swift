import ArrumatorCore
import SwiftUI

/// Every stage of how a document was processed: inputs, outputs, timings and the exact model exchange.
struct TraceView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let documentID: Int64
    @State private var traces: [TraceRecord] = []
    @State private var traceID: Int64?
    @State private var steps: [TraceStepRecord] = []

    var body: some View {
        VStack(alignment: .leading) {
            HStack {
                Picker("Run", selection: $traceID) {
                    ForEach(traces) { t in
                        Text("\(t.startedAt.formatted(date: .abbreviated, time: .standard)) · \(t.source) · \(t.outcome ?? "…")").tag(Int64?.some(t.id ?? 0))
                    }
                }
                .frame(maxWidth: 480)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            List(steps) { s in
                DisclosureGroup {
                    if let e = s.error { Text(e).foregroundStyle(.red).textSelection(.enabled) }
                    if let i = s.inputJson { payload("Input", i) }
                    if let o = s.outputJson { payload("Output", o) }
                } label: {
                    HStack {
                        Text(s.stage).bold().frame(width: 100, alignment: .leading)
                        Text(s.status).foregroundStyle(s.status == "error" ? .red : (s.status == "warn" ? .orange : .secondary))
                        Spacer()
                        Text("\(Int(s.durationMs)) ms").monospacedDigit().foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding()
        .task {
            traces = await model.load("Load traces") { try await $0.traces.traces(docID: documentID) } ?? []
            traceID = traces.first?.id
        }
        .task(id: traceID) {
            guard let traceID else { return }
            guard let loaded = await model.load("Load trace", { try await $0.traces.trace(id: traceID) }) ?? nil else { return }
            steps = loaded.1
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
