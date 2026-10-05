import ArrumatorCore
import SwiftUI

/// What is being worked on, what is waiting, and what was just filed, by day as on the Processed page: the whole
/// flow on one page. In Progress is the file the worker has in hand now, as its status says
/// (`IngestStatus.progress(of:)`), with what is being done to it, by which model, and for how long; every other file
/// waits under Queued, in the order the queue takes them, a file stopped part way, as when the app quit, saying that it
/// carries on where it stopped. Documents read again with the rest of the archive, which give way to those, are counted
/// in a notice above them, not listed (`JobStore.listed(inHand:)`). Beneath its name, a file shows the tags it
/// will be given, such as the name of the folder in Incoming it was put in (`JobRecord.tags`), as a document shows its
/// labels.
struct IncomingPage: View {
    @Environment(AppModel.self) private var model
    @State private var jobs: [JobRecord] = []
    /// What was just processed, under the day it was, as the list shows it.
    @State private var recent: [DocumentSection] = []
    @State private var recentCount = 0

    private var working: [JobRecord] { jobs.filter { model.session.ingest.progress(of: $0)?.isWorking == true } }
    private var queued: [JobRecord] { jobs.filter { model.session.ingest.progress(of: $0)?.isWorking == false } }

    var body: some View {
        Page(.incoming) {
            if let attention = model.attention {
                Notice(text: attention, action: holdupAction)
            }
            if model.session.ingest.readingAgain > 0 {
                Notice(text: Wording.readingAllAgain(model.session.ingest.readingAgain))
            }
            if model.session.ingest.reindexing > 0 {
                Notice(text: Wording.reindexing(model.session.ingest.reindexing))
            }
            if jobs.isEmpty {
                EmptyState(symbol: "tray", text: model.runtimeActivity.holdup == .notSetUp ? Wording.nothingWaitingNotSetUp : Wording.nothingWaiting) {
                    Button(Wording.openIncomingFolder) { if let path = model.settings?.incomingURL.path { model.open(path) } }
                }
            }
            if !working.isEmpty {
                PageSection(Wording.inProgress) {
                    ForEach(working) { job in
                        if let progress = model.session.ingest.progress(of: job), case let .working(work) = progress {
                            // How long counts on by itself from when the stage began, as a search task's reading does.
                            TimelineView(.periodic(from: work.since, by: Style.readingTimeTick)) { context in
                                let elapsed = context.date.timeIntervalSince(work.since)
                                ListRow(symbol: progress.symbol, tint: progress.tint, title: job.filename,
                                        detail: Wording.doing(work, elapsed: elapsed >= Style.readingTimeShownAfter ? elapsed : nil),
                                        subtitle: Wording.labels(job.tags), subtitleKind: .tag, busy: true)
                            }
                        }
                    }
                }
            }
            if !queued.isEmpty {
                PageSection(Wording.queuedHeading) {
                    ForEach(queued) { job in
                        if let progress = model.session.ingest.progress(of: job) {
                            ListRow(symbol: progress.symbol, tint: progress.tint, title: job.filename, detail: waiting(job, progress),
                                    subtitle: Wording.labels(job.tags), subtitleKind: .tag)
                        }
                    }
                }
            }
            // What was just processed reads as it does on the Processed page, which holds the rest.
            DocumentSections(sections: recent)
            if let limit = model.runtime?.config.interface.recentlyProcessed, recentCount == limit {
                Button(Wording.showMoreInProcessed) { model.go(.processed) }.buttonStyle(.link)
            }
        }
        // Reloaded as the worker takes a file, moves it on and finishes it, too, which History does not record.
        .task(id: model.ingestActivity) { await load() }
    }

    /// Reads the queue and what was just processed. A read cut short by a newer one keeps what is shown until the newer
    /// one has read it.
    private func load() async {
        let inHand = model.session.ingest.current?.job
        if let active = await model.load(Wording.loadQueueAction, { try await $0.services.jobs.listed(inHand: inHand) }) {
            jobs = active
        }
        if let processed = await model.load(Wording.loadProcessedAction, {
            try await $0.services.documents.list(DocumentFilter(statuses: DocumentStatus.processed), order: .recentlyProcessed,
                                                 limit: $0.config.interface.recentlyProcessed)
        }) {
            recentCount = processed.count
            recent = DocumentSection.sections(of: model.listed(processed), heading: Wording.processedDay)
        }
    }

    /// What lets filing go on from the notice that says why it does not: Resume while it is paused, Set Up before the
    /// app is set up (`RuntimeActivity.Holdup`).
    private var holdupAction: (title: String, run: () -> Void)? {
        switch model.runtimeActivity.holdup {
        case .paused: (Wording.resume, { Task { await model.setPaused(false) } })
        case .notSetUp: (Wording.setUpApp, { model.show(.onboarding) })
        default: nil
        }
    }

    /// What a file in the queue waits for: its turn, since it arrived; carrying on where it stopped; to be tried again
    /// after its error; or Ollama, which another file found away, until that one is tried again.
    private func waiting(_ job: JobRecord, _ progress: JobProgress) -> String {
        switch progress {
        case let .retrying(error, at): error + (at.map(Wording.retrying(at:)) ?? "")
        case .resuming: Wording.carriesOn(arrived: job.createdAt)
        case let .waitingForOllama(until): Wording.waitingForOllama(until: until)
        case .waiting, .working: Wording.arrived(job.createdAt)
        }
    }
}

extension JobRecord {
    var filename: String { (sourcePath as NSString).lastPathComponent }
}
