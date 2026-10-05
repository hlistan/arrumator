import ArrumatorCore
import Foundation

/// An archiver double (`FolderArchiving`) that writes, in place of a ZIP archive, the paths of the files it was given
/// below the folder, the folder's own name first, one a line, as they are on disk: what Core handed over to be packed,
/// which a test reads back (`files(in:)`). `ZipFolderArchiver` is tested in the extraction tests, with ZIPFoundation.
public struct ListingArchiver: FolderArchiving {
    public init() {}

    public func zip(_ directory: URL, to destination: URL) throws {
        let files = try FileManager.default.subpathsOfDirectory(atPath: directory.path).filter { path in
            (try? directory.appendingPathComponent(path).resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
        }
        let listing = files.sorted().map { directory.lastPathComponent + "/" + $0 }.joined(separator: "\n")
        try Data(listing.utf8).write(to: destination, options: .withoutOverwriting)
    }

    /// The files a listing at `url` names, as `zip` wrote them, each in NFC to compare as people read them.
    public static func files(in url: URL) throws -> Set<String> {
        Set(try String(contentsOf: url, encoding: .utf8).split(separator: "\n").map { String($0).precomposedStringWithCanonicalMapping })
    }
}
