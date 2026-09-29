import Foundation
import ZIPFoundation

enum ZipReadError: Error, CustomStringConvertible {
    case notAnArchive(String)
    case entryTooLarge(path: String, cap: Int)

    var description: String {
        switch self {
        case let .notAnArchive(reason): "Not a readable ZIP archive: \(reason)"
        case let .entryTooLarge(path, cap): "ZIP entry \(path) exceeds \(cap) bytes"
        }
    }
}

/// Read-only access to ZIP entries with a decompressed-size cap (protects against ZIP bombs). Not `Sendable`:
/// create, use and drop it within one task.
struct ZipReader {
    private let archive: Archive
    private let entryCap: Int

    init(url: URL, entryCap: Int) throws(ZipReadError) {
        do {
            archive = try Archive(url: url, accessMode: .read)
        } catch {
            throw .notAnArchive(String(describing: error))
        }
        self.entryCap = entryCap
    }

    /// All entries in archive order.
    var entries: [Entry] { Array(archive) }

    /// Decompressed bytes of the entry at `path`, or `nil` if absent.
    func data(at path: String) throws -> Data? {
        guard let entry = archive[path] else { return nil }
        guard entry.uncompressedSize <= UInt64(entryCap) else { throw ZipReadError.entryTooLarge(path: path, cap: entryCap) }
        var data = Data()
        let cap = entryCap
        _ = try archive.extract(entry, skipCRC32: true) { chunk in
            guard data.count + chunk.count <= cap else { throw ZipReadError.entryTooLarge(path: path, cap: cap) }
            data.append(chunk)
        }
        return data
    }
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

    /// `prefix:*` metadata of the OOXML package at `url`; empty when it has no readable core properties.
    static func metadata(of url: URL, entryCap: Int, prefix: String) -> [String: String] {
        guard let zip = try? ZipReader(url: url, entryCap: entryCap),
              let properties = try? read(from: zip) else { return [:] }
        return properties.metadata(prefix: prefix)
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
