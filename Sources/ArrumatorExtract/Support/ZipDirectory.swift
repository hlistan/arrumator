import ArrumatorCore
import Foundation

/// Why a ZIP file, or an entry of one, is not read.
enum ZipReadError: Error, LocalizedError, CustomStringConvertible {
    case unreadable(String)
    case corrupted(String)
    case tooManyEntries(count: UInt64, limit: Int)
    case entryTooLarge(path: String, cap: Int)
    case encrypted(path: String)

    var description: String {
        switch self {
        case let .unreadable(reason): "Cannot read the ZIP file: \(reason)"
        case let .corrupted(reason): "Not a readable ZIP archive: \(reason)"
        case let .tooManyEntries(count, limit): "ZIP archive lists \(count) entries, more than \(limit)"
        case let .entryTooLarge(path, cap): "ZIP entry \(path) exceeds \(cap) bytes"
        case let .encrypted(path): "ZIP entry \(path) is encrypted"
        }
    }

    var errorDescription: String? { description }

    /// The warning a file gets when it is refused for this reason.
    var warning: ExtractionWarning {
        switch self {
        case .tooManyEntries, .entryTooLarge: ExtractionWarning(.tooLarge, description)
        case .encrypted: ExtractionWarning(.encrypted, description)
        case .unreadable, .corrupted: ExtractionWarning(.corrupted, description)
        }
    }
}

/// One entry of a ZIP archive's central directory, as checked against the file.
struct ZipEntry: Sendable {
    enum Kind: Sendable { case file, directory, symlink }

    /// Its name (`ZipEntryName`).
    let path: String
    /// Its name decoded as its UTF-8 flag says, as ZIPFoundation's `Entry.path` spells it: what pairs the two listings.
    let flaggedPath: String
    let kind: Kind
    /// What it declares it unpacks to: its ZIP64 value when its 32-bit field is all ones (APPNOTE 4.5.3), zero too.
    let uncompressedSize: UInt64
    /// Whether its data is encrypted (APPNOTE 4.4.4, general purpose bit 0). ZIPFoundation reads no such entry.
    let isEncrypted: Bool

    /// Whether its data is unpacked, by ZIPFoundation: a file, not encrypted, that holds something. A folder has no
    /// data, and an empty file is read as empty without it, as ZIPFoundation would take an empty file's size from its
    /// all-ones 32-bit field (it takes a ZIP64 value only above zero) and read 4 GB of it.
    var isUnpacked: Bool { kind == .file && !isEncrypted && uncompressedSize > 0 }
}

/// The central directory of a ZIP file, read and checked against the file's length before any library opens it.
///
/// ZIPFoundation traps, ending the process, on an offset beyond `Int64.max` and on sizes whose sum overflows, and it
/// takes every offset and size from the file. So this reads the records it reads, found as it finds them, and refuses
/// the file unless every one lies inside it: the end of central directory record (APPNOTE 4.3.16), the ZIP64 end of
/// central directory locator and record (4.3.15, 4.3.14) where ZIPFoundation finds them, each central directory header
/// (4.3.12) with its ZIP64 extended information (4.5.3), and each local file header (4.3.7) with the data it
/// introduces. Every sum of values from the file reports overflow rather than trapping. No two entries may share a
/// byte of the file: entries that do are the overlapping-file ZIP bomb (Fifield, "A better zip bomb", WOOT 2019,
/// https://www.bamsoftware.com/hacks/zipbomb/; Info-ZIP UnZip refuses them since its fix for CVE-2019-13232), which
/// makes one part be read, and its local header copied, once for each name it is given. The count of entries is held
/// to the limit given. What the entries declare they unpack to is not: a declared size can lie either way, so what an
/// entry unpacks to is capped while it is unpacked (`ZipReader`). A file in Incoming is read only after it stopped
/// changing, so what ZIPFoundation then reads is what was checked.
///
/// Specification: PKWARE, *APPNOTE.TXT - .ZIP File Format Specification*, version 6.3.10,
/// https://pkware.cachefly.net/webdocs/casestudies/APPNOTE.TXT
struct ZipDirectory {
    let entries: [ZipEntry]

    static func read(_ url: URL, maxEntries: Int) throws(ZipReadError) -> ZipDirectory {
        let file = try ZipFile(url)
        let end = try EndOfCentralDirectory.find(in: file)
        guard end.entryCount <= UInt64(maxEntries) else {
            throw .tooManyEntries(count: end.entryCount, limit: maxEntries)
        }
        guard let directoryEnd = sum(end.directoryOffset, end.directorySize), directoryEnd <= end.offset else {
            throw .corrupted("the central directory lies outside the file")
        }
        var entries: [ZipEntry] = []
        var spans: [Range<UInt64>] = []
        var position = end.directoryOffset
        for _ in 0..<Int(end.entryCount) {
            let header = try CentralDirectoryHeader(file, at: position, before: directoryEnd)
            let entry = header.entry
            spans.append(try header.localSpan(in: file, before: end.directoryOffset, unpacked: entry.isUnpacked))
            entries.append(entry)
            position = header.end
        }
        let ordered = spans.sorted { $0.lowerBound < $1.lowerBound }
        guard zip(ordered, ordered.dropFirst()).allSatisfy({ $0.upperBound <= $1.lowerBound }) else {
            throw .corrupted("two entries share bytes of the file")
        }
        return ZipDirectory(entries: entries)
    }

    /// `values` added up, or `nil` if the sum overflows.
    static func sum(_ values: UInt64...) -> UInt64? { sum(values) }

    /// `values` added up, or `nil` if the sum overflows.
    static func sum(_ values: some Sequence<UInt64>) -> UInt64? {
        var total: UInt64 = 0
        for value in values {
            let (result, overflowed) = total.addingReportingOverflow(value)
            if overflowed { return nil }
            total = result
        }
        return total
    }
}

/// The end of central directory record, with the ZIP64 record when ZIPFoundation would use it.
private struct EndOfCentralDirectory {
    let offset: UInt64
    let entryCount: UInt64
    let directorySize: UInt64
    let directoryOffset: UInt64

    static let signature: UInt32 = 0x0605_4B50
    static let size: UInt64 = 22
    /// The record is at most this far from the end: itself and the longest comment (APPNOTE 4.3.16).
    static let maxDistanceFromEnd = size + UInt64(UInt16.max)
    static let zip64LocatorSignature: UInt32 = 0x0706_4B50
    static let zip64LocatorSize: UInt64 = 20
    static let zip64RecordSignature: UInt32 = 0x0606_4B50
    static let zip64RecordSize: UInt64 = 56
    /// The version a ZIP64 record needs to extract, 4.5 (APPNOTE 4.4.3.2).
    static let zip64Version: UInt16 = 45

    /// The record nearest the end of `file`, as ZIPFoundation's search from the end finds it.
    static func find(in file: ZipFile) throws(ZipReadError) -> EndOfCentralDirectory {
        guard file.length >= size else { throw .corrupted("too short to be a ZIP archive") }
        let searched = min(file.length, maxDistanceFromEnd)
        let tail = try file.bytes(at: file.length - searched, count: Int(searched))
        var start = tail.count - Int(size)
        while start >= 0, tail.uint32(at: start) != signature { start -= 1 }
        guard start >= 0 else { throw .corrupted("no end of central directory record") }
        let offset = file.length - searched + UInt64(start)
        let commentLength = UInt64(tail.uint16(at: start + 20))
        guard let recordEnd = ZipDirectory.sum(offset, size, commentLength), recordEnd <= file.length else {
            throw .corrupted("the archive comment runs past the end of the file")
        }
        if let zip64 = try zip64(in: file, before: offset) { return zip64 }
        return EndOfCentralDirectory(offset: offset, entryCount: UInt64(tail.uint16(at: start + 10)),
                                     directorySize: UInt64(tail.uint32(at: start + 12)),
                                     directoryOffset: UInt64(tail.uint32(at: start + 16)))
    }

    /// The ZIP64 record ZIPFoundation would use: a locator just before the record at `offset`, and a record of the
    /// fixed size just before the locator.
    private static func zip64(in file: ZipFile, before offset: UInt64) throws(ZipReadError) -> EndOfCentralDirectory? {
        guard offset > zip64LocatorSize, offset - zip64LocatorSize > zip64RecordSize else { return nil }
        let locatorOffset = offset - zip64LocatorSize
        let recordOffset = locatorOffset - zip64RecordSize
        let locator = try file.bytes(at: locatorOffset, count: Int(zip64LocatorSize))
        let record = try file.bytes(at: recordOffset, count: Int(zip64RecordSize))
        guard locator.uint32(at: 0) == zip64LocatorSignature, record.uint32(at: 0) == zip64RecordSignature,
              record.uint16(at: 14) >= zip64Version else { return nil }
        return EndOfCentralDirectory(offset: recordOffset, entryCount: record.uint64(at: 32),
                                     directorySize: record.uint64(at: 40), directoryOffset: record.uint64(at: 48))
    }
}

/// A central directory file header (APPNOTE 4.3.12), with the values ZIPFoundation takes from it.
private struct CentralDirectoryHeader {
    let end: UInt64
    let name: Data
    let flags: UInt16
    let method: UInt16
    let versionMadeBy: UInt16
    let externalAttributes: UInt32
    /// The sizes the entry declares (APPNOTE 4.5.3).
    let compressedSize: UInt64
    let uncompressedSize: UInt64
    /// The sizes ZIPFoundation takes it to have, which it reads and computes with (`effective…`).
    let libraryCompressedSize: UInt64
    let libraryUncompressedSize: UInt64
    let localHeaderOffset: UInt64

    static let signature: UInt32 = 0x0201_4B50
    static let size: UInt64 = 46
    static let stored: UInt16 = 0
    static let encryptedFlag: UInt16 = 1
    static let dataDescriptorFlag: UInt16 = 1 << 3
    static let utf8NameFlag: UInt16 = 1 << 11
    /// The least a data descriptor takes: its CRC-32 and two 32-bit sizes, as its signature is optional (APPNOTE 4.3.9).
    static let dataDescriptorMinSize: UInt64 = 12

    init(_ file: ZipFile, at position: UInt64, before directoryEnd: UInt64) throws(ZipReadError) {
        guard let fixedEnd = ZipDirectory.sum(position, Self.size), fixedEnd <= directoryEnd else {
            throw .corrupted("the central directory ends inside an entry")
        }
        let fixed = try file.bytes(at: position, count: Int(Self.size))
        guard fixed.uint32(at: 0) == Self.signature else { throw .corrupted("a central directory entry is damaged") }
        let nameLength = UInt64(fixed.uint16(at: 28))
        let extraLength = UInt64(fixed.uint16(at: 30))
        let commentLength = UInt64(fixed.uint16(at: 32))
        guard let end = ZipDirectory.sum(fixedEnd, nameLength, extraLength, commentLength), end <= directoryEnd else {
            throw .corrupted("the central directory ends inside an entry")
        }
        let variable = try file.bytes(at: fixedEnd, count: Int(nameLength + extraLength))
        self.end = end
        name = variable.prefix(Int(nameLength))
        versionMadeBy = fixed.uint16(at: 4)
        flags = fixed.uint16(at: 8)
        method = fixed.uint16(at: 10)
        externalAttributes = fixed.uint32(at: 38)
        let compressed = fixed.uint32(at: 20)
        let uncompressed = fixed.uint32(at: 24)
        let disk = fixed.uint16(at: 34)
        let offset = fixed.uint32(at: 42)
        let extended = ZIP64ExtendedInformation(in: Data(variable.suffix(Int(extraLength))),
                                                compressed: compressed, uncompressed: uncompressed,
                                                offset: offset, disk: disk)
        let isZIP64 = UInt8(truncatingIfNeeded: fixed.uint16(at: 6)) >= EndOfCentralDirectory.zip64Version
            || extended != nil
        // As ZIPFoundation's `effective…` values: the ZIP64 value where the entry is ZIP64 and gives one above zero.
        func effective(_ value: UInt32, _ wide: UInt64?) -> UInt64 {
            if isZIP64, let wide, wide > 0 { return wide }
            return UInt64(value)
        }
        libraryCompressedSize = effective(compressed, extended?.compressedSize)
        libraryUncompressedSize = effective(uncompressed, extended?.uncompressedSize)
        // A ZIP64 value is there only for a 32-bit field of all ones, and stands for it whatever it is.
        compressedSize = extended?.compressedSize ?? UInt64(compressed)
        uncompressedSize = extended?.uncompressedSize ?? UInt64(uncompressed)
        localHeaderOffset = effective(offset, extended?.localHeaderOffset)
    }

    /// The bytes of the file the entry takes, from its local header to the end of its data and of the least a data
    /// descriptor after it takes, once they are checked as everything ZIPFoundation reads or computes from them must be:
    /// the local header before the central directory, where a data descriptor would be a place in a file, and, for an
    /// entry it unpacks (`unpacked`, `ZipEntry.isUnpacked`), the data it reads before the central directory, a stored
    /// entry's by the size it says it unpacks to. An entry it does not unpack, a folder, an empty or an encrypted file,
    /// takes the data it declares.
    func localSpan(in file: ZipFile, before directoryOffset: UInt64,
                   unpacked: Bool) throws(ZipReadError) -> Range<UInt64> {
        guard let headerEnd = ZipDirectory.sum(localHeaderOffset, LocalFileHeader.size), headerEnd <= directoryOffset else {
            throw .corrupted("an entry's local header lies outside the archive")
        }
        let local = try LocalFileHeader(file, at: localHeaderOffset)
        let outside = ZipReadError.corrupted("an entry's data lies outside the archive")
        guard let dataStart = ZipDirectory.sum(headerEnd, local.nameLength, local.extraLength) else { throw outside }
        // ZIPFoundation looks for a data descriptor after the data it takes the entry to have, at an `off_t`.
        let descriptorAt = ZipDirectory.sum(dataStart, method == Self.stored ? libraryUncompressedSize : libraryCompressedSize)
        guard flags & Self.dataDescriptorFlag == 0 || descriptorAt.map({ $0 <= UInt64(Int64.max) }) == true else {
            throw outside
        }
        guard let dataEnd = ZipDirectory.sum(dataStart, unpacked ? libraryCompressedSize : compressedSize),
              dataEnd <= directoryOffset else { throw outside }
        var end = dataEnd
        // A stored entry is read by the size it says it unpacks to.
        if unpacked, method == Self.stored || local.method == Self.stored {
            guard let storedEnd = ZipDirectory.sum(dataStart, libraryUncompressedSize), storedEnd <= directoryOffset else {
                throw outside
            }
            end = max(end, storedEnd)
        }
        if flags & Self.dataDescriptorFlag != 0 {
            guard let descriptorEnd = ZipDirectory.sum(end, Self.dataDescriptorMinSize) else { throw outside }
            end = descriptorEnd
        }
        return localHeaderOffset..<end
    }

    var entry: ZipEntry {
        let path = ZipEntryName.decode(name)
        return ZipEntry(path: path, flaggedPath: ZipEntryName.decode(name, asFlagged: flags & Self.utf8NameFlag != 0),
                        kind: kind(path: path), uncompressedSize: uncompressedSize,
                        isEncrypted: flags & Self.encryptedFlag != 0)
    }

    /// What ZIPFoundation's `Entry.type` says: the Unix file type where the entry was made on Unix or macOS
    /// (APPNOTE 4.4.2, 4.4.15), else a directory by its DOS attribute or a name ending in `/`.
    private func kind(path: String) -> ZipEntry.Kind {
        let endsInSlash = path.hasSuffix("/")
        switch versionMadeBy >> 8 {
        case Self.madeOnUnix, Self.madeOnMac:
            switch mode_t(UInt16(truncatingIfNeeded: externalAttributes >> 16)) & S_IFMT {
            case S_IFREG: return .file
            case S_IFDIR: return .directory
            case S_IFLNK: return .symlink
            default: return endsInSlash ? .directory : .file
            }
        case Self.madeOnDOS:
            return endsInSlash || externalAttributes >> 4 == Self.dosDirectoryAttribute ? .directory : .file
        default:
            return endsInSlash ? .directory : .file
        }
    }

    private static let madeOnDOS: UInt16 = 0
    private static let madeOnUnix: UInt16 = 3
    private static let madeOnMac: UInt16 = 19
    private static let dosDirectoryAttribute: UInt32 = 0x01
}

/// The ZIP64 extended information extra field (APPNOTE 4.5.3), read as ZIPFoundation reads it: found among the extra
/// fields by its header ID, holding a value for each 32-bit field set to all ones, in this order, and only when its
/// size is exactly theirs.
private struct ZIP64ExtendedInformation {
    let uncompressedSize: UInt64?
    let compressedSize: UInt64?
    let localHeaderOffset: UInt64?

    static let headerID: UInt16 = 0x0001
    static let headerSize = 4

    init?(in extra: Data, compressed: UInt32, uncompressed: UInt32, offset: UInt32, disk: UInt16) {
        let hasUncompressed = uncompressed == .max
        let hasCompressed = compressed == .max
        let hasOffset = offset == .max
        let hasDisk = disk == .max
        let size = (hasUncompressed ? 8 : 0) + (hasCompressed ? 8 : 0) + (hasOffset ? 8 : 0) + (hasDisk ? 4 : 0)
        var position = 0
        while position < extra.count - Self.headerSize {
            let next = position + Self.headerSize + Int(extra.uint16(at: position + 2))
            guard next <= extra.count else { return nil }
            if extra.uint16(at: position) == Self.headerID {
                guard next - position == Self.headerSize + size else { return nil }
                var field = position + Self.headerSize
                func value(_ present: Bool) -> UInt64? {
                    guard present else { return nil }
                    defer { field += 8 }
                    return extra.uint64(at: field)
                }
                uncompressedSize = value(hasUncompressed)
                compressedSize = value(hasCompressed)
                localHeaderOffset = value(hasOffset)
                return
            }
            position = next
        }
        return nil
    }
}

/// A local file header (APPNOTE 4.3.7): what ZIPFoundation reads of it to find an entry's data.
private struct LocalFileHeader {
    let method: UInt16
    let nameLength: UInt64
    let extraLength: UInt64

    static let signature: UInt32 = 0x0403_4B50
    static let size: UInt64 = 30

    init(_ file: ZipFile, at offset: UInt64) throws(ZipReadError) {
        let fixed = try file.bytes(at: offset, count: Int(Self.size))
        guard fixed.uint32(at: 0) == Self.signature else { throw .corrupted("an entry's local header is damaged") }
        method = fixed.uint16(at: 8)
        nameLength = UInt64(fixed.uint16(at: 26))
        extraLength = UInt64(fixed.uint16(at: 28))
    }
}

/// Entry names: UTF-8 when the bytes are valid UTF-8, else code page 437, composed (NFC) either way.
///
/// APPNOTE 4.4.4 and appendix D give a name without the UTF-8 flag (general purpose bit 11) code page 437, but
/// archivers write UTF-8 names without the flag, and a name of high bytes in code page 437 is seldom valid UTF-8 by
/// chance, so the bytes decide rather than the flag. A name leaves the Mac composed (AGENTS.md §3), and the Mac's own
/// archiver writes them decomposed.
enum ZipEntryName {
    static func decode(_ bytes: Data) -> String {
        let name = String(validating: bytes, as: UTF8.self) ?? String(data: bytes, encoding: codePage437) ?? ""
        return name.precomposedStringWithCanonicalMapping
    }

    /// The name as ZIPFoundation decodes it (`Entry.path`): UTF-8 when the flag says so, else code page 437, as written.
    static func decode(_ bytes: Data, asFlagged isUTF8: Bool) -> String {
        String(data: bytes, encoding: isUTF8 ? .utf8 : codePage437) ?? ""
    }

    /// IBM PC code page 437, the encoding of names without the UTF-8 flag (APPNOTE appendix D).
    static let codePage437 = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
        CFStringEncoding(CFStringEncodings.dosLatinUS.rawValue)))
}

/// A file read at offsets, every read checked to be inside it.
private struct ZipFile {
    let length: UInt64
    private let handle: FileHandle

    init(_ url: URL) throws(ZipReadError) {
        do {
            handle = try FileHandle(forReadingFrom: url)
            length = try handle.seekToEnd()
        } catch {
            throw .unreadable(error.localizedDescription)
        }
    }

    func bytes(at offset: UInt64, count: Int) throws(ZipReadError) -> Data {
        guard let end = ZipDirectory.sum(offset, UInt64(count)), end <= length else {
            throw .corrupted("a record runs past the end of the file")
        }
        do {
            try handle.seek(toOffset: offset)
            let data = try handle.read(upToCount: count) ?? Data()
            guard data.count == count else { throw ZipReadError.corrupted("the file ended early") }
            return data
        } catch let error as ZipReadError {
            throw error
        } catch {
            throw .unreadable(error.localizedDescription)
        }
    }
}

private extension Data {
    func uint16(at offset: Int) -> UInt16 { UInt16(littleEndian: load(at: offset)) }
    func uint32(at offset: Int) -> UInt32 { UInt32(littleEndian: load(at: offset)) }
    func uint64(at offset: Int) -> UInt64 { UInt64(littleEndian: load(at: offset)) }

    private func load<T: FixedWidthInteger>(at offset: Int) -> T {
        withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: T.self) }
    }
}
