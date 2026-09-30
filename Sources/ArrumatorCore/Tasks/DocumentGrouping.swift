import Foundation

/// Arranges documents by their labels, a level per kind, as a search task shows its set and exports it as folders. At
/// each level a document goes with its first label of the kind, the most significant; a date, period or deadline goes by
/// its year. Labels written alike but for case, accents or punctuation are one group. The groups follow in the order a
/// person looks for them: years newest first, anything else alphabetically, and the documents without a label of the
/// kind last. Within a group documents follow their date, then their name.
public enum DocumentGrouping {
    public static func tree(_ documents: [DocumentRecord], by kinds: [LabelKind]) -> LabelGroup {
        LabelGroup(kind: nil, value: nil, groups: groups(documents, kinds[...]), documents: kinds.isEmpty ? ordered(documents) : [])
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
                          documents: rest.isEmpty ? ordered(bucket.documents) : [])
        }
    }

    /// By date, the undated last, then by name.
    private static func ordered(_ documents: [DocumentRecord]) -> [DocumentRecord] {
        documents.sorted { a, b in
            let (x, y) = (a.labels(.date).first, b.labels(.date).first)
            if x != y {
                guard let x else { return false }
                guard let y else { return true }
                return x < y
            }
            return a.filename.localizedStandardCompare(b.filename) == .orderedAscending
        }
    }
}
