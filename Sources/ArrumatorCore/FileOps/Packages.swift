import Foundation
import UniformTypeIdentifiers

/// A package, a folder macOS shows as one document (an `.rtfd`, a Pages document), is one document on every path that
/// sees it, events and scans alike (docs/review/swift-apple.md F12): a path inside a package is the package. The
/// watchers find the document an event is about by `document(holding:under:)`, as a scan that skips what packages hold
/// (`skipsPackageDescendants`) sees only the package, and the queue by `document(holding:incoming:)`; a package is
/// weighed, hashed and opened by what it holds, in one walk of it (`survey`, `FileFingerprint.of`,
/// `HashService.sha256`), and moved whole.
public enum Packages {
    /// The document the item at `url` belongs to, spelled as the file system spells it (`URL.spelledOnDisk`): the
    /// outermost package that holds it below `incoming`, as the watcher takes it, when it is in Incoming, so a folder
    /// above Incoming is never taken for one; anywhere on its path, when it is elsewhere, as `arrumatorcli ingest` may
    /// name it; or the item itself.
    public static func document(holding url: URL, incoming: URL) -> URL {
        let (item, folder) = (url.spelledOnDisk, incoming.folderOnDisk)
        let root = item.path.hasPrefix(folder.path + "/") ? folder : URL(fileURLWithPath: "/", isDirectory: true)
        return document(holding: item, under: root)
    }

    /// The document the item at `url` belongs to: the outermost package below `root` that holds it, or `url` itself
    /// when none does, as for a file of its own or a package in no other. `url` and `root` are spelled alike, as the
    /// watcher that asks spells both; a path not below `root` is its own document.
    static func document(holding url: URL, under root: URL) -> URL {
        let (parts, base) = (url.pathComponents, root.pathComponents)
        guard parts.count > base.count + 1, Array(parts.prefix(base.count)) == base else { return url }
        var folder = root
        for name in parts[base.count..<(parts.count - 1)] {
            folder.appendPathComponent(name, isDirectory: true)
            if isPackage(folder) { return folder }
        }
        return url
    }

    /// How many items are listed between two checks whether the work was stopped, in a package and in a folder a
    /// watcher looks through: a size that changes no result, only how soon a stop is noticed.
    static let chunk = 256

    /// Whether the item at `url` is a package: as the file system says while it is there, and, once it is gone, as the
    /// type its extension declares says (`UTType(filenameExtension:conformingTo:)`, a type the system or an app
    /// declares, not one made up for an unknown extension), so an event about what a package removed held is about the
    /// package.
    static func isPackage(_ url: URL) -> Bool {
        if let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey]) {
            return values.isDirectory == true && values.isPackage == true
        }
        guard !url.pathExtension.isEmpty, let type = UTType(filenameExtension: url.pathExtension, conformingTo: .package) else {
            return false
        }
        return !type.isDynamic
    }

    /// An item a package holds, at any depth, as one walk of it found it.
    struct Entry: Sendable, Hashable {
        enum Kind: Sendable, Hashable { case file, folder, link, other }

        /// Where it is in the package, its names composed (NFC) and joined by `/`: the same however the disk writes
        /// them, as a copy on another volume may write them decomposed.
        let path: String
        let url: URL
        let kind: Kind
        /// Its size, for a file.
        let size: Int64?
        let modified: Date?
        /// Whether this process may read it, as the file system says without opening it.
        let isReadable: Bool
    }

    /// Throws `FileOperationError.tooManyItems` when the item at `url` is a package of more than `limit` items, listing
    /// no more of it than that: what a file named to be filed is checked by before anything reads it whole.
    static func check(_ url: URL, holdsAtMost limit: Int) throws {
        guard isPackage(url) else { return }
        _ = try entries(of: url, limit: limit)
    }

    /// What one walk of a package finds: its fingerprint (`FileFingerprint.of`) and whether this process may read
    /// every file in it, which nothing is opened to tell, so no walk can be held up by what it meets.
    struct Survey: Sendable, Equatable {
        let fingerprint: FileFingerprint
        let isReadable: Bool
    }

    /// Weighs the package at `package` in one walk: the sum of its files' sizes, the latest change to it or anything in
    /// it, its identity on the volume, and whether every file in it may be read. Throws `FileOperationError.tooManyItems`
    /// when it holds more than `limit` items, before listing more, and when any of it cannot be listed.
    static func survey(_ package: URL, limit: Int?) throws -> Survey {
        let attrs = try FileManager.default.attributesOfItem(atPath: package.path)
        var size: Int64 = 0
        var latest = attrs[.modificationDate] as? Date
        var readable = true
        for entry in try entries(of: package, limit: limit) {
            if entry.kind == .file, let bytes = entry.size {
                // Sizes the disk reports, added up: a sum past what Int64 holds stays at its largest rather than trap.
                let (sum, overflow) = size.addingReportingOverflow(bytes)
                size = overflow ? .max : sum
            }
            if let changed = entry.modified, changed > latest ?? .distantPast { latest = changed }
            if entry.kind == .file, !entry.isReadable { readable = false }
        }
        return Survey(fingerprint: FileFingerprint(size: size, modified: latest, inode: (attrs[.systemFileNumber] as? NSNumber)?.int64Value),
                      isReadable: readable)
    }

    /// Everything the package at `package` holds, hidden items too, as the disk lists them, at most `limit`. A link is
    /// listed, never followed. Throws when any of it cannot be listed: what cannot be listed cannot be weighed, hashed or
    /// opened. Throws `CancellationError` when its task is cancelled, which it checks every `chunk` items, so a stop is
    /// never held behind a large package.
    static func entries(of package: URL, limit: Int?) throws -> [Entry] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey,
                                      .contentModificationDateKey, .isReadableKey]
        var failure: (any Error)?
        guard let walker = FileManager.default.enumerator(at: package, includingPropertiesForKeys: keys, options: [], errorHandler: { _, error in
            failure = failure ?? error
            return true
        }) else { throw CocoaError(.fileReadUnknown, userInfo: [NSFilePathErrorKey: package.path]) }
        var entries: [Entry] = []
        // The names from the package down to the item listed last: a listing may spell the package's own path otherwise
        // than `package` (`/private/var` for `/var`), so where an item is is told by its depth, not by its path.
        var names: [String] = []
        for case let url as URL in walker {
            if let limit, entries.count >= limit { throw FileOperationError.tooManyItems(package.path, limit: limit) }
            if !entries.isEmpty, entries.count.isMultiple(of: chunk) { try Task.checkCancellation() }
            names = Array(names.prefix(walker.level - 1)) + [url.lastPathComponent.precomposedStringWithCanonicalMapping]
            let values = try url.resourceValues(forKeys: Set(keys))
            let kind: Entry.Kind = values.isSymbolicLink == true ? .link
                : values.isRegularFile == true ? .file : values.isDirectory == true ? .folder : .other
            entries.append(Entry(path: names.joined(separator: "/"), url: url, kind: kind, size: values.fileSize.map(Int64.init),
                                 modified: values.contentModificationDate, isReadable: values.isReadable == true))
        }
        if let failure { throw failure }
        return entries
    }
}
