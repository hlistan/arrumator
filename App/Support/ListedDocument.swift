import ArrumatorCore
import ArrumatorRuntime
import Foundation

/// A document as a list shows it, its words worked out once, when it is read, rather than each time a view's body is:
/// they decode what the model read of it and its labels, and format dates.
struct ListedDocument: Identifiable {
    let record: DocumentRecord
    /// Where it is, or what happened to it; nil for a document filed in the archive, as most are.
    let detail: String?
    /// Where it is, or what happened to it, always said.
    let outcome: String
    /// Its labels on one line.
    let labels: String?
    /// Its own date, as its label gives it.
    let date: String?
    /// Why Core would refuse to remove it now (`ReviewActions.removalRefusals`), read with the list; nil when it can be.
    let removalRefusal: IngestError?

    var id: Int64? { record.id }

    init(_ record: DocumentRecord, archive: URL?, incoming: URL?, removalRefusal: IngestError? = nil) {
        self.record = record
        self.removalRefusal = removalRefusal
        detail = Wording.rowDetail(of: record, archive: archive, incoming: incoming)
        outcome = Wording.outcome(of: record, archive: archive, incoming: incoming)
        labels = Wording.labels(record.labels)
        date = record.documentDate
    }
}

/// Documents under one heading of a list, in the order they come.
struct DocumentSection: Identifiable {
    let title: String
    let documents: [ListedDocument]

    var id: String { title }

    /// `documents` under headings, in the order they come, a heading wherever `heading` names another than the one
    /// before.
    static func sections(of documents: [ListedDocument], heading: (DocumentRecord) -> String) -> [DocumentSection] {
        var out: [(title: String, documents: [ListedDocument])] = []
        for document in documents {
            let title = heading(document.record)
            if out.last?.title == title { out[out.count - 1].documents.append(document) } else { out.append((title, [document])) }
        }
        return out.map { DocumentSection(title: $0.title, documents: $0.documents) }
    }
}

extension AppModel {
    /// `documents` as a list shows them, in the archive the app is on, each with why it cannot be removed now, if it
    /// cannot, as read with the list (`ReviewActions.removalRefusals`).
    func listed(_ documents: [DocumentRecord], refusals: [Int64: IngestError] = [:]) -> [ListedDocument] {
        let (archive, incoming) = (archive, settings?.incomingURL)
        return documents.map { ListedDocument($0, archive: archive, incoming: incoming, removalRefusal: $0.id.flatMap { refusals[$0] }) }
    }

    /// Reads for display (`load`) what `read` gives with the documents it names, and, read at once with them, why each cannot
    /// be removed now (`ReviewActions.removalRefusals`): the one place a page pairs a list with its refusals.
    func load<T: Sendable>(_ what: String, withRefusals read: (ArrumatorRuntime) async throws -> (value: T, documents: [DocumentRecord]))
        async -> (value: T, refusals: [Int64: IngestError])? {
        await load(what) { runtime in
            let (value, documents) = try await read(runtime)
            return (value, try await runtime.review.removalRefusals(of: documents))
        }
    }

    /// The documents `read` gives, as a list shows them, each with why it cannot be removed now; nil as `load` gives it.
    func loadListed(_ what: String, _ read: (ArrumatorRuntime) async throws -> [DocumentRecord]) async -> [ListedDocument]? {
        guard let (documents, refusals) = await load(what, withRefusals: { runtime in
            let documents = try await read(runtime)
            return (documents, documents)
        }) else { return nil }
        return listed(documents, refusals: refusals)
    }
}
