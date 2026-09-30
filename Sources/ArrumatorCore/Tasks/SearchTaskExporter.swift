import Foundation

/// Copies a search task's set out of the archive: into a new folder named after the task, holding a folder for each
/// group of the first kind the set is arranged by, a folder inside it for each group of the next, and the documents at
/// the bottom, each under its own file name; or into a ZIP archive of that folder. Documents are copied, never moved,
/// and nothing already there is written over: a folder, archive or file whose name is taken gets the collision suffix
/// (`naming.collisionFormat`). The app builds every path: a folder is named after its label as a file name is cleaned
/// (`FilenameBuilder`), so a label can never reach another directory (AGENTS.md §4.5).
struct SearchTaskExporter {
    let naming: NamingConfig
    let tasks: TasksConfig
    /// Folders an export may not go into: the archive and Incoming, which would take the copies in as documents.
    let excluded: [URL]

    private var builder: FilenameBuilder { FilenameBuilder(config: naming) }
    private var operations: FileOperations { FileOperations(naming: naming) }

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
        let name = builder.bounded(detail.task.name, fileExtension: "")
        let top = name.isEmpty ? String(detail.task.id) : name
        switch format {
        case .folder:
            let (root, _) = try operations.uniqueDestination(directory: folder, filename: top)
            return (root, try copy(detail.tree, into: root))
        case .zip:
            // The folder is put together beside where the archive goes, then packed; the temporary folder holds only the
            // copies made here, and goes when the archive is made.
            let staging = try FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: folder, create: true)
            defer { try? FileManager.default.removeItem(at: staging) }
            let root = staging.appendingPathComponent(top, isDirectory: true)
            let manifest = try copy(detail.tree, into: root)
            let (archive, _) = try operations.uniqueDestination(directory: folder, filename: top + "." + Self.zipExtension)
            try Self.zip(root, to: archive)
            return (archive, manifest)
        }
    }

    static let zipExtension = "zip"

    /// Copies a group's documents into `directory`, and each group below it into a folder of its own there.
    private func copy(_ group: LabelGroup, into directory: URL, at path: [String] = []) throws -> ExportManifest {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw SearchTaskError.exportFailed(directory.path, error.localizedDescription)
        }
        var manifest = ExportManifest(files: [], skipped: [])
        for document in group.documents {
            guard let id = document.id else { continue }
            guard FileManager.default.fileExists(atPath: document.path) else {
                manifest.skipped.append(SkippedFile(document: id, reason: "\(document.path) is not there"))
                continue
            }
            do {
                let (target, _) = try operations.uniqueDestination(directory: directory, filename: document.filename)
                try FileManager.default.copyItem(at: document.url, to: target)
                manifest.files.append(ExportedFile(document: id, path: (path + [target.lastPathComponent]).joined(separator: "/")))
            } catch {
                manifest.skipped.append(SkippedFile(document: id, reason: error.localizedDescription))
            }
        }
        for child in group.groups {
            let name = try folderName(child)
            let inner = try copy(child, into: directory.appendingPathComponent(name, isDirectory: true), at: path + [name])
            manifest.files += inner.files
            manifest.skipped += inner.skipped
        }
        return manifest
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
        let name = shown.map { builder.bounded($0, fileExtension: "") } ?? ""
        return name.isEmpty ? builder.bounded(try tasks.withoutLabelFolder(kind), fileExtension: "") : name
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
