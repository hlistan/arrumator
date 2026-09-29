import ArrumatorCore
import SwiftUI

/// What is being worked on, what is waiting, and what was just decided, by day as on the Processed page: the whole
/// flow on one page.
struct IncomingPage: View {
    @Environment(AppModel.self) private var model
    @State private var jobs: [JobRecord] = []
    @State private var recent: [DocumentRecord] = []

    private var working: [JobRecord] { jobs.filter { $0.state != .pending } }
    private var queued: [JobRecord] { jobs.filter { $0.state == .pending } }

    var body: some View {
        Page(.incoming) {
            if let attention = model.attention {
                Notice(text: attention, action: model.settings?.paused == true
                    ? ("Resume", { Task { await model.togglePause() } }) : nil)
            }
            if model.ingest.reindexing > 0 {
                Notice(text: "Reading \(Format.count(model.ingest.reindexing, "document")) again for search, after the index was "
                    + "rebuilt from the archive. New files still come first.")
            }
            if jobs.isEmpty {
                EmptyState(symbol: "tray", text: "Nothing waiting. Files dropped into Incoming are picked up on their own.") {
                    Button("Open Incoming Folder") { if let path = model.settings?.incomingURL.path { model.open(path) } }
                }
            }
            if !working.isEmpty {
                PageSection("In Progress") {
                    ForEach(working) { job in
                        ListRow(symbol: "circle", tint: .secondary, title: job.filename, detail: step(job.state), busy: true)
                    }
                }
            }
            if !queued.isEmpty {
                PageSection("Queued") {
                    ForEach(queued) { job in
                        ListRow(symbol: job.lastError == nil ? "circle" : "exclamationmark.circle",
                                tint: job.lastError == nil ? .secondary : Palette.attention,
                                title: job.filename, detail: waiting(job))
                    }
                }
            }
            // What was just processed reads as it does on the Processed page, which holds the rest.
            ProcessedDays(documents: recent)
            if let limit = model.runtime?.config.interface.recentlyProcessed, recent.count == limit {
                Button("Show More in Processed") { model.go(.processed) }.buttonStyle(.link)
            }
        }
        .task(id: model.activity) { await load() }
    }

    private func load() async {
        jobs = await model.load("Load queue") { try await $0.services.jobs.active(kinds: [.ingest, .adopt, .reclassify]) } ?? []
        recent = await model.load("Load processed documents") {
            try await $0.services.documents.list(DocumentFilter(statuses: DocumentStatus.processed), order: .recentlyProcessed,
                                                 limit: $0.config.interface.recentlyProcessed)
        } ?? []
    }

    /// Where a job is, in the words the processing funnel uses.
    private func step(_ state: JobState) -> String {
        model.runtime?.config.stats.funnel.steps.first { $0.jobStates.contains(state) }?.title ?? state.rawValue
    }

    private func waiting(_ job: JobRecord) -> String {
        if let error = job.lastError {
            let retry = job.nextRunAt.map { " · retrying at \($0.formatted(date: .omitted, time: .shortened))" } ?? ""
            return error + retry
        }
        return "arrived \(job.createdAt.formatted(.relative(presentation: .named)))"
    }
}

extension JobRecord {
    var filename: String { (sourcePath as NSString).lastPathComponent }
}
