import Foundation
import GRDB

extension ReviewActions {
    /// Puts back the document removed under `number`, as it was (`putBack(_:)` of its latest removal not yet put back):
    /// when every removal of it is put back already, that is what is refused (`PutBackError.alreadyPutBack`), and a
    /// number never removed is `PutBackError.notRemoved`. What it does is `putBack(removal:)`'s.
    @discardableResult
    public func putBack(_ number: Int64) async throws -> PutBackPayload {
        let removals = try await services.database.reader.read { db in
            try Removal.all(db, document: number).map { (removal: $0, done: try Removal.isPutBack(db, $0.eventID)) }
        }
        guard let latest = removals.first else { throw PutBackError.notRemoved(document: number) }
        guard let next = removals.first(where: { !$0.done }) else { throw PutBackError.alreadyPutBack(name: latest.removal.name) }
        return try await putBack(next.removal)
    }

    /// Puts back the document the removal recorded by event `eventID` took out: its file comes back from the Trash to where
    /// it was, or beside what took its place there, or at the top of the archive (or of Incoming) when its folder is gone,
    /// and the document into the index and its record file with the number, identity, name, status, labels (those given by
    /// hand still the user's own) and reading it had, with the user's rules about labels made since applied to them as to
    /// every document (`LabelConsolidator.ruled`); its text and meaning are read again from its file without the model,
    /// as after a rebuild (a `reindex` job), and History records it once (`EventKind.documentPutBack`). What it does not
    /// bring back is what the removal cut from it: its place in tasks' sets, earlier events and traces, and the
    /// corrections counted before. Refused before anything changes, by the one rule the History listing applies
    /// (`PutBackRule`, `putBackRefusals(of:)`), and again, for what can change meanwhile, in the write that records it:
    /// the move and its record are made in a task of their own, which a stop does not cut between them, and a file
    /// brought back whose record then fails or does not commit goes back to exactly where it was in the Trash. Across
    /// volumes the file comes back as a copy checked against the document's checksum and the original stays in the Trash
    /// (`FileOperations.bringBack`), recorded as `copied`. Only a crash between the move and the commit, or a Trash that
    /// then refuses the copy to take it back (which is logged, and the record's own error thrown), leaves the file in the
    /// archive with no document, which the next start takes in as a new file, as any file put into the archive.
    @discardableResult
    public func putBack(removal eventID: Int64) async throws -> PutBackPayload {
        let event = try await services.database.reader.read { db in try EventRecord.fetchOne(db, key: eventID) }
        guard let event, let removal = Removal(event) else { throw PutBackError.noSuchRemoval(event: eventID) }
        return try await putBack(removal)
    }

    /// Why each of the removals among `events` cannot be put back now, by the number of its event; one that can is not in
    /// it. The rule `putBack` applies: the index in one read, and then, outside it, what the disk shows, except what only
    /// the content shows (that the file in the Trash hashes as the document), which only the action sees.
    public func putBackRefusals(of events: [EventRecord]) async throws -> [Int64: PutBackError] {
        let incoming = await services.settings.current.incomingURL.folderOnDisk
        let (archive, trash, packageItems) = (services.archive, services.trash, services.config.watcher.maxPackageItems)
        var refusals: [Int64: PutBackError] = [:]
        // A removal whose payload cannot be read is refused as the action refuses it; an event of another kind is no row.
        let removals = events.filter { $0.kind == .documentRemoved }.compactMap { event -> Removal? in
            let removal = Removal(event)
            if removal == nil, let id = event.id { refusals[id] = .noSuchRemoval(event: id) }
            return removal
        }
        let looked = try await services.database.reader.read { db in
            try removals.map { (removal: $0, checked: try PutBackRule.checked(db, $0, archive: archive, incoming: incoming)) }
        }
        for (removal, checked) in looked {
            try Task.checkCancellation()
            switch checked {
            case let .failure(refusal): refusals[removal.eventID] = refusal
            case let .success(checked):
                if let refusal = await PutBackRule.onDisk(removal, checked, trash: trash, packageItems: packageItems) {
                    refusals[removal.eventID] = refusal
                }
            }
        }
        return refusals
    }

    /// Where a document's file goes back to: the folder it was in when that is still there inside the folder it belongs to,
    /// else the top of that folder; and the free name it takes there.
    private struct Placement {
        let destination: URL
        /// The number of the name taken, when the name it had is taken by another file now.
        let collision: Int?
        let folderGone: Bool
        let root: URL
    }

    private func placement(of removal: Removal, in checked: PutBackRule.Checked) throws -> Placement {
        let root = checked.root
        let folder = checked.folder.isEmpty ? root : root.appendingPathComponent(checked.folder, isDirectory: true)
        let there = ArchiveRecords.isFolder(folder)
        let (destination, collision) = try services.filer.placer.builder.uniqueDestination(
            directory: there ? folder : root, filename: URL(fileURLWithPath: removal.payload.from).lastPathComponent)
        return Placement(destination: destination, collision: collision, folderGone: !there, root: root)
    }

    private func putBack(_ removal: Removal) async throws -> PutBackPayload {
        let name = removal.name
        let incoming = await services.settings.current.incomingURL.folderOnDisk
        let (archive, database) = (services.archive, services.database)
        let checked = try await database.reader.read { db in try PutBackRule.checked(db, removal, archive: archive, incoming: incoming) }.get()
        if let refusal = await PutBackRule.onDisk(removal, checked, trash: services.trash, packageItems: services.config.watcher.maxPackageItems) {
            throw refusal
        }
        let (entry, trashedPath) = (checked.entry, checked.trashed)
        let trashed = URL(fileURLWithPath: trashedPath)
        // The whole file is hashed here, never in the write that holds the index's lock.
        let (fingerprint, hashed) = try await PutBackRule.reading(trashedPath, name: name)
        guard hashed == entry.sha256 else { throw PutBackError.notItsFile(name: name, trashed: trashedPath) }
        let place = try placement(of: removal, in: checked)
        try Task.checkCancellation()
        // The archive's watcher is told, so the file coming back is no change of the user's to follow.
        await services.filer.registry.expect([place.destination.path])
        let (operations, now, vocabulary) = (services.filer.placer.operations, services.time.now(), services.config.labels.vocabulary)
        let brought = Kept<MoveResult>()
        let put: PutBackPayload
        do {
            put = try await Task {
                try await database.writer.write { db in
                    if let refusal = try PutBackRule.inIndex(db, removal, entry: entry) { throw refusal }
                    guard let current = try? FileFingerprint.of(trashed) else { throw PutBackError.noLongerInTrash(name: name, trashed: trashedPath) }
                    guard current.matches(fingerprint) else { throw PutBackError.notItsFile(name: name, trashed: trashedPath) }
                    let taken = try DocumentRecord.fetchOne(db, key: entry.id) != nil
                    let moved: MoveResult
                    do {
                        moved = try operations.bringBack(trashed, to: place.destination, within: place.root, expectedSHA256: entry.sha256)
                    } catch {
                        throw PutBackError.notMoved(name: name, reason: error.localizedDescription)
                    }
                    brought.keep(moved)
                    var kept = entry
                    // The user's rules made since, as every document is given them: a label merged is the label merged into, one
                    // removed for good is not given again, none is made another unasked; given by hand, it stays so. Only the
                    // rules decide that (`ruled`); the labels in use matter to suggestions alone, so none is counted here.
                    let rules = LabelConsolidator(config: vocabulary, rules: try LabelStore.orderedRules(db), vocabulary: [:])
                    kept.labels = entry.labels.map { rules.ruled($0).labels }
                    kept.byHand = entry.byHand.map { hand in rules.ruled(hand).labels.filter { kept.labels?.contains($0) == true } }
                    kept.file = place.destination.lastPathComponent
                    if let other = kept.duplicateOf, try DocumentRecord.fetchOne(db, key: other) == nil { kept.duplicateOf = nil }
                    var record = try kept.record(directory: place.destination.deletingLastPathComponent(), now: now)
                    record.path = place.destination.path
                    record.id = taken ? nil : entry.id
                    if let there = try? FileFingerprint.of(place.destination) {
                        (record.size, record.inode, record.fileMtime) = (there.size, there.inode, there.modified)
                    }
                    try record.insert(db)
                    guard let id = record.id else { throw IngestError.documentNotPersisted }
                    try JobStore.enqueue(db, path: place.destination.path, kind: .reindex, docID: id, payload: JobPayload(), givesWay: true, at: now)
                    let removedAs = taken ? entry.id : nil
                    let payload = PutBackPayload(removal: removal.eventID, document: id, removedAs: removedAs,
                                                 from: trashedPath, to: place.destination.spelledOnDisk.path,
                                                 copied: moved.crossVolume ? true : nil)
                    try HistoryStore.insert(db, .documentPutBack, at: now, actor: .user, doc: id,
                                            summary: Self.putBackSummary(name: name, placed: place, as: record.filename, number: (id, removedAs)),
                                            payload: payload)
                    return payload
                }
            }.value
        } catch {
            // Not put back after all, as its record failed or did not commit: its file goes back where it was in the Trash.
            if let moved = brought.kept {
                do { try operations.takeBack(moved) } catch let back {
                    Log.error(.fileops, "Could not take a file back to the Trash", ["path": moved.to, "error": back.localizedDescription])
                }
            }
            throw error
        }
        await coordinator.wake()
        return put
    }

    /// What History says of a put-back: the file it came back from the Trash, and, as named parts, what differed from where
    /// it was.
    private static func putBackSummary(name: String, placed: Placement, as filename: String, number: (new: Int64, was: Int64?)) -> String {
        var parts = ["Put back “\(name)” from the Trash"]
        if placed.collision != nil { parts.append("another file is at its place, so it is beside it as “\(filename)”") } else if filename != name {
            parts.append("it comes back as “\(filename)”, the name its file had when it was removed")
        }
        if placed.folderGone { parts.append("its folder is gone, so it is at the top of \(placed.root.lastPathComponent)") }
        if let was = number.was { parts.append("its number \(was) is another document's, so it is document \(number.new)") }
        return parts.joined(separator: "; ")
    }

}
