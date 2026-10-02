import ArrumatorCore
import Foundation
import ZIPFoundation

/// Read-only access to the entries of a ZIP file. Its central directory is checked against the file first
/// (`ZipDirectory`), so ZIPFoundation opens only a file whose every offset and size lies inside it, whose entries share
/// no byte and are within `zipMaxEntries`; then each entry is unpacked up to `zipEntryCapBytes`, held to that by what it
/// declares and by what it unpacks to (protects against ZIP bombs). An encrypted entry is never read. Not `Sendable`:
/// create, use and drop it within one task.
final class ZipReader {
    /// The entries, in the central directory's order.
    let entries: [ZipEntry]
    private let archive: Archive
    /// The place in `entries` of the first regular file of each name.
    private let files: [String: Int]
    private let entryCap: Int
    /// ZIPFoundation's entries of the parts asked for, by their place in `entries`: no more of them are held than parts
    /// are read, as each copies its headers' names and extra fields.
    private var located: [Int: Entry] = [:]

    init(url: URL, config: ExtractionConfig) throws(ZipReadError) {
        let directory = try ZipDirectory.read(url, maxEntries: config.zipMaxEntries)
        do {
            archive = try Archive(url: url, accessMode: .read)
        } catch {
            throw .corrupted(String(describing: error))
        }
        let entries = directory.entries
        self.entries = entries
        files = Dictionary(entries.indices.filter { entries[$0].kind == .file }.map { (entries[$0].path, $0) },
                           uniquingKeysWith: { first, _ in first })
        entryCap = config.zipEntryCapBytes
    }

    /// Finds ZIPFoundation's entries for the files at `paths` in one pass over its listing, so that many parts, such as a
    /// deck's slides, cost one pass and not one each. Its iterator takes one step through the central directory for each
    /// call, the same records `ZipDirectory` read, and answers `nil` for an encrypted entry, where a `for` loop or
    /// `dropFirst` would stop or slip by one; so it is called once for each entry up to the last one wanted, and each
    /// answer is checked against the entry it stands for, by its name as ZIPFoundation spells it.
    func locate(_ paths: some Sequence<String>) throws(ZipReadError) {
        let wanted = Set(paths.compactMap { files[$0] }).filter { located[$0] == nil && entries[$0].isUnpacked }
        guard let last = wanted.max() else { return }
        let listing = archive.makeIterator()
        for index in 0...last {
            let entry = entries[index]
            let next = listing.next()
            guard next?.path == (entry.isEncrypted ? nil : entry.flaggedPath) else {
                throw .corrupted("entry \(index + 1) of the central directory is read differently by ZIPFoundation")
            }
            if wanted.contains(index) { located[index] = next }
        }
    }

    /// The unpacked bytes of the file entry at `path`, or `nil` when there is none. An entry that declares, or
    /// unpacks to, more than the cap is refused.
    func data(at path: String) throws -> Data? {
        guard let index = files[path] else { return nil }
        guard entries[index].uncompressedSize <= UInt64(entryCap) else {
            throw ZipReadError.entryTooLarge(path: path, cap: entryCap)
        }
        let read = try unpack(index)
        guard !read.truncated else { throw ZipReadError.entryTooLarge(path: path, cap: entryCap) }
        return read.data
    }

    /// The first unpacked bytes of the file entry at `path`, up to the cap, and whether it goes on past them; `nil`
    /// when there is none. For a part that is still of use cut, such as the first rows of a long sheet.
    func head(at path: String) throws -> (data: Data, truncated: Bool)? {
        try files[path].map(unpack)
    }

    /// Unpacks the entry at `index` until it ends or fills the cap, which stops the unpacking. An empty file is empty
    /// without ZIPFoundation; another entry is located first when `locate` has not found it.
    private func unpack(_ index: Int) throws -> (data: Data, truncated: Bool) {
        guard !entries[index].isEncrypted else { throw ZipReadError.encrypted(path: entries[index].path) }
        guard entries[index].isUnpacked else { return (Data(), false) }
        if located[index] == nil { try locate([entries[index].path]) }
        guard let entry = located[index] else {
            throw ZipReadError.corrupted("entry \(entries[index].path) cannot be found")
        }
        var data = Data()
        var truncated = false
        let cap = entryCap
        do {
            _ = try archive.extract(entry, skipCRC32: true) { chunk in
                let room = cap - data.count
                guard chunk.count <= room else {
                    data.append(chunk.prefix(room))
                    truncated = true
                    throw CapReached()
                }
                data.append(chunk)
            }
        } catch is CapReached {}
        return (data, truncated)
    }

    /// Stops ZIPFoundation unpacking once the cap is full.
    private struct CapReached: Error {}
}

/// Dublin Core properties of an Office Open XML package (`docProps/core.xml`).
struct OOXMLCoreProperties: Sendable, Equatable {
    var title: String?
    var creator: String?
    var created: String?
    var modified: String?
    var lastModifiedBy: String?

    /// Metadata entries under `prefix` (`doc:title`, `doc:creator`, …), omitting empty values.
    func metadata(prefix: String) -> [String: String] {
        let pairs: [(String, String?)] = [("title", title), ("creator", creator), ("created", created),
                                          ("modified", modified), ("lastModifiedBy", lastModifiedBy)]
        return Dictionary(uniqueKeysWithValues: pairs.compactMap { key, value in
            guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
            return ("\(prefix):\(key)", value)
        })
    }

    /// `prefix:*` metadata of the OOXML package at `url`, as `metadata(in:prefix:)` gives it. A file that is no ZIP
    /// the checks pass has none and no warning here: a Word document is converted by `textutil`, which reads it whatever
    /// its container, and reports its own failure.
    static func metadata(of url: URL, config: ExtractionConfig,
                         prefix: String) -> (metadata: [String: String], warnings: [ExtractionWarning]) {
        guard let zip = try? ZipReader(url: url, config: config) else { return ([:], []) }
        return metadata(in: zip, prefix: prefix)
    }

    /// `prefix:*` metadata of the OOXML package `zip`; none when it has no core properties, and none with a warning
    /// when it has them but they are not read, as when the part is too large or encrypted.
    static func metadata(in zip: ZipReader,
                         prefix: String) -> (metadata: [String: String], warnings: [ExtractionWarning]) {
        do {
            return (try read(from: zip)?.metadata(prefix: prefix) ?? [:], [])
        } catch let error as ZipReadError {
            return ([:], [error.warning])
        } catch {
            return ([:], [ExtractionWarning(.corrupted, "core properties: \(error)")])
        }
    }

    static func read(from zip: ZipReader) throws -> OOXMLCoreProperties? {
        guard let data = try zip.data(at: "docProps/core.xml") else { return nil }
        let elements = XMLTextCollector.collect(data, elements: ["dc:title", "dc:creator", "dcterms:created",
                                                                 "dcterms:modified", "cp:lastModifiedBy"])
        return OOXMLCoreProperties(title: elements["dc:title"]?.first, creator: elements["dc:creator"]?.first,
                                   created: elements["dcterms:created"]?.first,
                                   modified: elements["dcterms:modified"]?.first,
                                   lastModifiedBy: elements["cp:lastModifiedBy"]?.first)
    }
}

/// Collects the text content of selected XML elements (by qualified name), in document order.
final class XMLTextCollector: NSObject, XMLParserDelegate {
    private let wanted: Set<String>
    private let paragraphElement: String?
    private var depthInWanted = 0
    private var current = ""
    private var currentName = ""
    private(set) var values: [String: [String]] = [:]
    /// Concatenated text of wanted elements, one line per `paragraphElement`.
    private(set) var paragraphs: [String] = []
    private var paragraph = ""

    private init(wanted: Set<String>, paragraphElement: String?) {
        self.wanted = wanted
        self.paragraphElement = paragraphElement
    }

    /// Text of each wanted element, keyed by qualified name.
    static func collect(_ data: Data, elements: Set<String>) -> [String: [String]] {
        let collector = XMLTextCollector(wanted: elements, paragraphElement: nil)
        collector.parse(data)
        return collector.values
    }

    /// Lines of text: the wanted runs (e.g. `a:t`) joined within each paragraph element (e.g. `a:p`).
    static func paragraphs(_ data: Data, runElement: String, paragraphElement: String) -> [String] {
        let collector = XMLTextCollector(wanted: [runElement], paragraphElement: paragraphElement)
        collector.parse(data)
        collector.flushParagraph()
        return collector.paragraphs
    }

    private func parse(_ data: Data) {
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = false
        parser.shouldResolveExternalEntities = false
        parser.delegate = self
        parser.parse()
    }

    private func flushParagraph() {
        let line = paragraph.trimmingCharacters(in: .whitespacesAndNewlines)
        if !line.isEmpty { paragraphs.append(line) }
        paragraph = ""
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        if wanted.contains(elementName) {
            if depthInWanted == 0 {
                current = ""
                currentName = elementName
            }
            depthInWanted += 1
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if depthInWanted > 0 { current += string }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?) {
        if wanted.contains(elementName), depthInWanted > 0 {
            depthInWanted -= 1
            if depthInWanted == 0 {
                values[currentName, default: []].append(current)
                paragraph += current
            }
        } else if elementName == paragraphElement {
            flushParagraph()
        }
    }
}
