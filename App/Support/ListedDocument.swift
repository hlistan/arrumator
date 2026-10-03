import ArrumatorCore
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

    var id: Int64? { record.id }

    init(_ record: DocumentRecord, archive: URL?, incoming: URL?) {
        self.record = record
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
    /// `documents` as a list shows them, in the archive the app is on.
    func listed(_ documents: [DocumentRecord]) -> [ListedDocument] {
        let (archive, incoming) = (archive, settings?.incomingURL)
        return documents.map { ListedDocument($0, archive: archive, incoming: incoming) }
    }
}
