import Foundation

/// Where a document's file is now, for every list that shows it: filed, waiting in Needs review, set aside as a
/// duplicate, or back in Incoming after an undo.
public enum DocumentPlace: Sendable, Hashable {
    /// In one of the archive's folders, system folders included, and in the year folder inside it when there is one.
    case folder(TaxonomyFolder, year: String?)
    /// In the Incoming folder.
    case incoming
    /// In a directory the archive's folders do not account for.
    case elsewhere(directory: String)
    /// The file is no longer on disk.
    case missing
}

extension TaxonomySnapshot {
    /// The folder a directory of documents belongs to: the folder itself, or the one around a year folder.
    public func folder(holding directory: URL) -> TaxonomyFolder? {
        let isYear = YearFolder.matches(directory.lastPathComponent)
        let owner = (isYear ? directory.deletingLastPathComponent() : directory).standardizedFileURL.path
        return folders.first { url(for: $0).standardizedFileURL.path == owner }
    }

    /// Where `document` is now. The folder it was filed into is known by number; a document whose folder has gone, or
    /// that was never filed, is placed by its path.
    public func place(of document: DocumentRecord, incoming: URL) -> DocumentPlace {
        guard document.status != .missing else { return .missing }
        let directory = document.url.deletingLastPathComponent()
        if let folder = document.folderId.flatMap(folder(id:)) ?? folder(holding: directory) {
            let own = url(for: folder).standardizedFileURL.path
            return .folder(folder, year: directory.standardizedFileURL.path == own ? nil : directory.lastPathComponent)
        }
        if (directory.standardizedFileURL.path + "/").hasPrefix(incoming.standardizedFileURL.path + "/") { return .incoming }
        return .elsewhere(directory: directory.path)
    }
}
