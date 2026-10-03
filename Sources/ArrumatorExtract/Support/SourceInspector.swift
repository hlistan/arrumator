import ArrumatorCore
import Foundation
import UniformTypeIdentifiers

/// File-system facts about a file, captured before extraction.
struct InspectedFile: Sendable {
    let source: SourceFile
    let type: UTType
}

/// Builds `SourceFile` (size, dates, `kMDItemWhereFroms`) and resolves the file's `UTType`.
enum SourceInspector {
    /// A package (`Packages`), a folder macOS shows as one document, is inspected as the document it is, its size what
    /// it holds; any other folder is refused.
    static func inspect(_ url: URL, sha256: String) throws(ExtractionError) -> InspectedFile {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isPackageKey, .fileSizeKey, .creationDateKey,
                                         .contentModificationDateKey, .contentTypeKey, .isReadableKey]
        let values: URLResourceValues
        do {
            values = try url.resourceValues(forKeys: keys)
        } catch {
            throw .fileUnreadable(path: url.path, underlying: error.localizedDescription)
        }
        let isDirectory = values.isDirectory ?? false
        guard values.isReadable ?? false else {
            throw .fileUnreadable(path: url.path, underlying: "not readable")
        }
        guard !isDirectory || (values.isPackage ?? false) else {
            throw .fileUnreadable(path: url.path, underlying: "is a folder")
        }
        let type = TypeResolver.resolve(url, contentType: values.contentType, isDirectory: isDirectory)
        let size: Int64
        do {
            size = isDirectory ? try FileFingerprint.of(url).size : Int64(values.fileSize ?? 0)
        } catch {
            throw .fileUnreadable(path: url.path, underlying: error.localizedDescription)
        }
        let source = SourceFile(path: url.path, originalFilename: url.lastPathComponent,
                                fileExtension: url.pathExtension.lowercased(), utType: type.identifier,
                                byteSize: size, createdAt: values.creationDate,
                                modifiedAt: values.contentModificationDate, sha256: sha256,
                                whereFroms: whereFroms(url))
        return InspectedFile(source: source, type: type)
    }

    /// Download origins recorded by browsers and Mail in the `com.apple.metadata:kMDItemWhereFroms` xattr
    /// (a binary property list of strings).
    static func whereFroms(_ url: URL) -> [String] {
        let name = "com.apple.metadata:kMDItemWhereFroms"
        let size = getxattr(url.path, name, nil, 0, 0, 0)
        guard size > 0 else { return [] }
        var buffer = Data(count: size)
        let read = buffer.withUnsafeMutableBytes { getxattr(url.path, name, $0.baseAddress, size, 0, 0) }
        guard read == size,
              let list = try? PropertyListSerialization.propertyList(from: buffer, format: nil) as? [String]
        else { return [] }
        return list.filter { !$0.isEmpty }
    }
}

/// Resolves a file's type: filename extension first, then the file system's content type, then magic bytes for
/// files without a usable extension.
enum TypeResolver {
    static func resolve(_ url: URL, contentType: UTType?, isDirectory: Bool) -> UTType {
        let ext = url.pathExtension
        let fromExtension = ext.isEmpty ? nil
            : UTType(filenameExtension: ext, conformingTo: isDirectory ? .package : .data)
        if let fromExtension, !fromExtension.isDynamic { return fromExtension }
        if let contentType, !contentType.isDynamic, contentType != .data { return contentType }
        if !isDirectory, let sniffed = sniff(url) { return sniffed }
        return fromExtension ?? contentType ?? .data
    }

    /// Signatures of common document formats, for files saved without an extension.
    private static let signatures: [(bytes: [UInt8], type: UTType)] = [
        (Array("%PDF-".utf8), .pdf),
        ([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A], .png),
        ([0xFF, 0xD8, 0xFF], .jpeg),
        (Array("GIF8".utf8), .gif),
        ([0x49, 0x49, 0x2A, 0x00], .tiff),
        ([0x4D, 0x4D, 0x00, 0x2A], .tiff),
        (Array("{\\rtf".utf8), .rtf),
        ([0x50, 0x4B, 0x03, 0x04], .zip),
    ]

    private static func sniff(_ url: URL) -> UTType? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let length = signatures.map(\.bytes.count).max() ?? 0
        guard let head = try? handle.read(upToCount: length) else { return nil }
        let bytes = [UInt8](head)
        return signatures.first { bytes.starts(with: $0.bytes) }?.type
    }
}
