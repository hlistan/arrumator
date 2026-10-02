import Foundation

/// Arranges documents by their labels, a level per kind, as a search task shows its set and exports it as folders. At
/// each level a document goes with its first label of the kind, the most significant; a date, period or deadline goes by
/// its year. Labels written alike but for case, accents or punctuation are one group. The groups follow in the order a
/// person looks for them: years newest first, anything else alphabetically, and the documents without a label of the
/// kind last. Within a group, and in a set listed without arranging it, documents follow their own date, the newest
/// first and the undated last, then their name (`DocumentOrder.documentDate`).
public enum DocumentGrouping {
    public static func tree(_ documents: [DocumentRecord], by kinds: [LabelKind]) -> LabelGroup {
        LabelGroup(kind: nil, value: nil, groups: groups(documents, kinds[...]),
                   documents: kinds.isEmpty ? DocumentOrder.byDocumentDate(documents) : [])
    }

    /// What a document is arranged by at a level of `kind`: its first label of the kind, or the year it stands for when
    /// the kind is one of time; nil when it has none.
    public static func value(of document: DocumentRecord, kind: LabelKind) -> String? {
        guard let label = document.labels(kind).first else { return nil }
        guard SearchPlan.timeKinds.contains(kind) else { return label }
        return TimeSpan(label)?.year ?? label
    }

    private static func groups(_ documents: [DocumentRecord], _ kinds: ArraySlice<LabelKind>) -> [LabelGroup] {
        guard let kind = kinds.first else { return [] }
        var buckets: [String?: (value: String?, documents: [DocumentRecord])] = [:]
        for document in documents {
            let value = value(of: document, kind: kind)
            let key = value.map { LabelUsage.searchKey($0).isEmpty ? $0 : LabelUsage.searchKey($0) }
            buckets[key, default: (value, [])].documents.append(document)
        }
        let newestFirst = SearchPlan.timeKinds.contains(kind)
        let rest = kinds.dropFirst()
        return buckets.values.sorted { a, b in
            guard let x = a.value else { return false }
            guard let y = b.value else { return true }
            return newestFirst ? x > y : x.localizedStandardCompare(y) == .orderedAscending
        }.map { bucket in
            LabelGroup(kind: kind, value: bucket.value, groups: groups(bucket.documents, rest),
                          documents: rest.isEmpty ? DocumentOrder.byDocumentDate(bucket.documents) : [])
        }
    }
}
