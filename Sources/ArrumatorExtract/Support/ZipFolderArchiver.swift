import ArrumatorCore
import Foundation
import ZIPFoundation

/// Packs a folder into a ZIP archive as other systems read it (`FolderArchiving`), for a search task's export: every
/// entry under the folder's own name, each name composed (NFC) whatever the disk holds, as a Mac may write names
/// decomposed, a letter then its accent, and marked as UTF-8 by the language encoding flag, general purpose bit 11
/// (APPNOTE.TXT 4.4.4 and appendix D), which ZIPFoundation sets on every entry it writes. Without the flag, `unzip`,
/// Python's `zipfile` and Windows read a name as code page 437, and "ФКП Росреестра" as "╨ñ╨Ü╨ƒ…", as they did the
/// archives Finder's Compress makes (`NSFileCoordinator.ReadingOptions.forUploading`). Files are compressed with deflate;
/// a folder is an entry of its own only when it is empty, as a file's path names the folders it is in. Entries follow
/// the order of their paths, so an archive of the same folder is the same.
public struct ZipFolderArchiver: FolderArchiving {
    public init() {}

    public func zip(_ directory: URL, to destination: URL) throws {
        let archive = try Archive(url: destination, accessMode: .create)
        let top = directory.lastPathComponent.precomposedStringWithCanonicalMapping
        // Paths below the folder, as the disk holds them, each a path relative to it.
        let below = try FileManager.default.subpathsOfDirectory(atPath: directory.path).sorted()
        for relative in below {
            let item = directory.appendingPathComponent(relative)
            let name = Self.entryName(relative, top: top)
            if try item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true {
                guard try FileManager.default.contentsOfDirectory(atPath: item.path).isEmpty else { continue }
                try archive.addEntry(with: name + "/", fileURL: item)
            } else {
                try archive.addEntry(with: name, fileURL: item, compressionMethod: .deflate)
            }
        }
    }

    /// The name of the entry for the item at `relative` below the folder: the folder's own name, `top`, then each name
    /// below it, each composed, joined by `/` (APPNOTE.TXT 4.4.17).
    static func entryName(_ relative: String, top: String) -> String {
        ([top] + relative.split(separator: "/").map { String($0).precomposedStringWithCanonicalMapping }).joined(separator: "/")
    }
}
