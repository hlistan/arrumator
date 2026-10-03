import Foundation

/// Copies a search task's set out of the archive: into a new folder named after the task, holding a folder for each
/// group of the first kind the set is arranged by, a folder inside it for each group of the next, and the documents at
/// the bottom, each under its own file name; or into a ZIP archive of that folder. Documents are copied, never moved,
/// and nothing already there is written over: a folder, archive or file whose name is taken gets the collision suffix
/// (`naming.collisionFormat`), and so does a group's folder whose name, once cleaned, is another's in the same folder,
/// however either is cased or composed, as the file system finds them alike. The app builds every path: a folder is
/// named after its label as a file name is cleaned (`FilenameBuilder`), so a label can never reach another directory
/// (AGENTS.md §4.5). Once the export's own folder is made, it is finished and recorded whatever fails in it: a document
/// that cannot be copied, or whose group's folder cannot be made, is skipped with the reason, so no folder is left that
/// its task does not record.
struct SearchTaskExporter {
    /// What cleans the names of the folders and finds free names for what is made.
    let builder: FilenameBuilder
    let tasks: TasksConfig
    /// Folders an export may not go into: the archive and Incoming, which would take the copies in as documents.
    let excluded: [URL]

    /// Exports the set into `folder`, made if it does not exist; returns the folder or archive made and what it holds.
    func export(_ detail: SearchTaskDetail, into folder: URL, format: ExportFormat) throws -> (URL, ExportManifest) {
        let folder = folder.standardizedFileURL
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory), !isDirectory.boolValue {
            throw SearchTaskError.destinationNotAFolder(folder.path)
        }
        guard !excluded.contains(where: { Self.isInside(folder, $0) }) else { throw SearchTaskError.destinationInsideArchive(folder.path) }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            throw SearchTaskError.exportFailed(folder.path, error.localizedDescription)
        }
        let top = builder.bounded(detail.task.name, fileExtension: "") ?? String(detail.task.id)
        switch format {
        case .folder:
            let (root, _) = try builder.uniqueDestination(directory: folder, filename: top)
            let manifest = copy(detail.tree, into: root)
            // Nothing could be made: no folder is left to record.
            guard FileManager.default.fileExists(atPath: root.path) else {
                throw SearchTaskError.exportFailed(root.path, manifest.skipped.first?.reason ?? "the folder could not be made")
            }
            return (root, manifest)
        case .zip:
            // The folder is put together beside where the archive goes, then packed; the temporary folder holds only the
            // copies made here, and goes when the archive is made.
            let staging = try FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: folder, create: true)
            defer { try? FileManager.default.removeItem(at: staging) }
            let root = staging.appendingPathComponent(top, isDirectory: true)
            let manifest = copy(detail.tree, into: root)
            let (archive, _) = try builder.uniqueDestination(directory: folder, filename: top + "." + Self.zipExtension)
            try Self.composeNames(under: root)
            try Self.zip(root, to: archive)
            return (archive, manifest)
        }
    }

    static let zipExtension = "zip"

    /// Copies a group's documents into `directory`, and each group below it into a folder of its own there. What cannot
    /// be copied is skipped with the reason: all of the group's documents, those of the groups below it too, when its
    /// folder cannot be made.
    private func copy(_ group: LabelGroup, into directory: URL, at path: [String] = []) -> ExportManifest {
        var manifest = ExportManifest(files: [], skipped: [])
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            manifest.skipped = Self.documents(of: group).map { SkippedFile(document: $0, reason: error.localizedDescription) }
            return manifest
        }
        var taken = Set<String>()
        for document in group.documents {
            guard let id = document.id else { continue }
            guard FileManager.default.fileExists(atPath: document.path) else {
                manifest.skipped.append(SkippedFile(document: id, reason: "\(document.path) is not there"))
                continue
            }
            do {
                let (target, _) = try builder.uniqueDestination(directory: directory, filename: document.filename)
                try FileManager.default.copyItem(at: document.url, to: target)
                taken.insert(Self.key(target.lastPathComponent))
                manifest.files.append(ExportedFile(document: id, path: (path + [target.lastPathComponent]).joined(separator: "/")))
            } catch {
                manifest.skipped.append(SkippedFile(document: id, reason: error.localizedDescription))
            }
        }
        for child in group.groups {
            let name: String
            do { name = unique(try folderName(child), among: &taken) } catch {
                manifest.skipped += Self.documents(of: child).map { SkippedFile(document: $0, reason: error.localizedDescription) }
                continue
            }
            let inner = copy(child, into: directory.appendingPathComponent(name, isDirectory: true), at: path + [name])
            manifest.files += inner.files
            manifest.skipped += inner.skipped
        }
        return manifest
    }

    /// `name`, or with the collision suffix when a name in `taken` is alike (`key`), which it then joins.
    private func unique(_ name: String, among taken: inout Set<String>) -> String {
        var candidate = name
        var n = 1
        while taken.contains(Self.key(candidate)) {
            n += 1
            candidate = name + String(format: builder.config.collisionFormat, n)
        }
        taken.insert(Self.key(candidate))
        return candidate
    }

    /// How the file system tells names apart: APFS and HFS+ as macOS formats them by default find a name whatever its
    /// case or Unicode composition.
    static func key(_ name: String) -> String { name.precomposedStringWithCanonicalMapping.lowercased() }

    /// The documents of `group` and of every group below it.
    static func documents(of group: LabelGroup) -> [Int64] {
        group.documents.compactMap(\.id) + group.groups.flatMap { documents(of: $0) }
    }

    /// A group's folder: its label as people read it (a type by its name, a language by its English name), cleaned as a
    /// file name is, or `tasks.withoutLabelFolder` for the documents without one.
    func folderName(_ group: LabelGroup) throws -> String {
        guard let kind = group.kind else { return "" }
        let shown = group.value.map { value in
            switch kind {
            case .type: DocumentType(rawValue: value)?.label ?? value
            case .language: DocumentLabel.languageName(value) ?? value
            default: value
            }
        }
        return try shown.flatMap { builder.bounded($0, fileExtension: "") }
            ?? builder.bounded(tasks.withoutLabelFolder(kind), fileExtension: "") ?? ""
    }

    /// Renames everything under `directory` to its composed (NFC) name. A Mac may write names decomposed, a letter then
    /// its accent, and a ZIP archive keeps the bytes it finds, which other systems show as loose marks ("Joa\u{0303}o").
    /// POSIX `rename` writes the bytes it is given, whatever the name looks like as a `String`, and the file system finds a
    /// name however it is composed; the deepest names go first, so every parent path still holds.
    static func composeNames(under directory: URL) throws {
        let walker = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil)
        let entries = (walker?.allObjects as? [URL] ?? []).sorted { $0.pathComponents.count > $1.pathComponents.count }
        for entry in entries {
            let name = entry.lastPathComponent, composed = name.precomposedStringWithCanonicalMapping
            let parent = entry.deletingLastPathComponent().path
            guard rename(parent + "/" + name, parent + "/" + composed) == 0 else {
                throw SearchTaskError.exportFailed(entry.path, String(cString: strerror(errno)))
            }
        }
    }

    /// Packs `directory` into a ZIP archive at `destination`, as Finder's Compress does: Foundation zips a directory read
    /// for uploading (Apple, `NSFileCoordinator.ReadingOptions.forUploading`), into a temporary file it removes once the
    /// block returns, so the block copies it out.
    static func zip(_ directory: URL, to destination: URL) throws {
        var coordination: NSError?
        var copying: (any Error)?
        NSFileCoordinator().coordinate(readingItemAt: directory, options: [.forUploading], error: &coordination) { zipped in
            do { try FileManager.default.copyItem(at: zipped, to: destination) } catch { copying = error }
        }
        if let error = coordination ?? copying { throw SearchTaskError.exportFailed(destination.path, error.localizedDescription) }
    }

    /// Whether `url` is `root` or inside it, however either is spelled: through a link, `/private` or not, in any case.
    static func isInside(_ url: URL, _ root: URL) -> Bool {
        let paths = { (u: URL) in Set([u.standardizedFileURL.path, u.resolvingSymlinksInPath().path, u.canonicalFolderPath ?? u.path].map { $0.lowercased() }) }
        let (candidates, roots) = (paths(url), paths(root))
        return candidates.contains { c in roots.contains { r in c == r || c.hasPrefix(r + "/") } }
    }
}
