import ArrumatorCore
import SwiftUI

/// What is being worked on, what is waiting, and what was just filed, by day as on the Processed page: the whole
/// flow on one page. In Progress is the file the worker has in hand now, as its status says
/// (`IngestStatus.progress(of:)`); every other file waits under Queued, in the order the queue takes them, a file stopped
/// part way, as when the app quit, saying that it carries on where it stopped. Beneath its name, a file shows the tags it
/// will be given, such as the name of the folder in Incoming it was put in (`JobRecord.tags`), as a document shows its
/// labels.
struct IncomingPage: View {
    @Environment(AppModel.self) private var model
    @State private var jobs: [JobRecord] = []
    @State private var recent: [DocumentRecord] = []

    private var working: [JobRecord] { jobs.filter { model.ingest.progress(of: $0)?.isWorking == true } }
    private var queued: [JobRecord] { jobs.filter { model.ingest.progress(of: $0)?.isWorking == false } }

    var body: some View {
        Page(.incoming) {
            if let attention = model.attention {
                Notice(text: attention, action: model.settings?.paused == true
                    ? (Wording.resume, { Task { await model.setPaused(false) } }) : nil)
            }
            if model.ingest.reindexing > 0 {
                Notice(text: Wording.reindexing(model.ingest.reindexing))
            }
            if jobs.isEmpty {
                EmptyState(symbol: "tray", text: Wording.nothingWaiting) {
                    Button(Wording.openIncomingFolder) { if let path = model.settings?.incomingURL.path { model.open(path) } }
                }
            }
            if !working.isEmpty {
                PageSection(Wording.inProgress) {
                    ForEach(working) { job in
                        if let progress = model.ingest.progress(of: job), case let .working(stage) = progress {
                            ListRow(symbol: progress.symbol, tint: progress.tint, title: job.filename, detail: Wording.doing(stage),
                                    subtitle: Wording.labels(job.tags), subtitleKind: .tag, busy: true)
                        }
                    }
                }
            }
            if !queued.isEmpty {
                PageSection(Wording.queuedHeading) {
                    ForEach(queued) { job in
                        if let progress = model.ingest.progress(of: job) {
                            ListRow(symbol: progress.symbol, tint: progress.tint, title: job.filename, detail: waiting(job, progress),
                                    subtitle: Wording.labels(job.tags), subtitleKind: .tag)
                        }
                    }
                }
            }
            // What was just processed reads as it does on the Processed page, which holds the rest.
            DocumentSections(documents: recent, heading: Wording.processedDay)
            if let limit = model.runtime?.config.interface.recentlyProcessed, recent.count == limit {
                Button(Wording.showMoreInProcessed) { model.go(.processed) }.buttonStyle(.link)
            }
        }
        // Reloaded as the worker takes a file, moves it on and finishes it, too, which History does not record.
        .task(id: model.ingestActivity) { await load() }
    }

    /// Reads the queue and what was just processed. A read cut short by a newer one keeps what is shown until the newer
    /// one has read it.
    private func load() async {
        if let active = await model.load(Wording.loadQueueAction, { try await $0.services.jobs.active(kinds: [.ingest, .adopt, .reanalyse]) }) {
            jobs = active
        }
        if let processed = await model.load(Wording.loadProcessedAction, {
            try await $0.services.documents.list(DocumentFilter(statuses: DocumentStatus.processed), order: .recentlyProcessed,
                                                 limit: $0.config.interface.recentlyProcessed)
        }) {
            recent = processed
        }
    }

    /// What a file in the queue waits for: its turn, since it arrived; carrying on where it stopped; or to be tried again
    /// after its error.
    private func waiting(_ job: JobRecord, _ progress: JobProgress) -> String {
        switch progress {
        case let .retrying(error, at): error + (at.map(Wording.retrying(at:)) ?? "")
        case .resuming: Wording.carriesOn(arrived: job.createdAt)
        case .waiting, .working: Wording.arrived(job.createdAt)
        }
    }
}

extension JobRecord {
    var filename: String { (sourcePath as NSString).lastPathComponent }
}
