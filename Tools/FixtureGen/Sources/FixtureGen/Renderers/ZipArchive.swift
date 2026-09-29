import Foundation

/// Builds ZIP containers (DOCX, XLSX) reproducibly: entries are written in a fixed order, with one fixed
/// timestamp, by `/usr/bin/zip -X` (no extra fields) running in UTC so the DOS time does not depend on the
/// machine's time zone.
struct ZipArchive {
    let settings: RenderSettings

    func archive(_ entries: [(path: String, data: Data)]) throws -> Data {
        let workspace = try Workspace()
        defer { workspace.remove() }
        let stamp = settings.archive.entryTimestamp.date
        for entry in entries {
            let url = workspace.content.appending(path: entry.path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try entry.data.write(to: url)
            try FileManager.default.setAttributes([.modificationDate: stamp], ofItemAtPath: url.path)
        }
        try Shell.run("/usr/bin/zip", ["-X", "-r", "-q", "-nw", workspace.archive.path] + entries.map(\.path),
                      in: workspace.content, environment: ["TZ": "UTC"])
        return try Data(contentsOf: workspace.archive)
    }

    /// Re-packs a ZIP produced by another writer (AppKit's DOCX exporter stamps the current time on every entry).
    func normalize(_ zip: Data) throws -> Data {
        let workspace = try Workspace()
        defer { workspace.remove() }
        try zip.write(to: workspace.archive)
        let listing = try Shell.run("/usr/bin/unzip", ["-Z1", workspace.archive.path])
        let paths = String(decoding: listing, as: UTF8.self).split(separator: "\n").map(String.init).filter { !$0.hasSuffix("/") }
        // Extract everything rather than by name: unzip treats "[" in "[Content_Types].xml" as a wildcard.
        try Shell.run("/usr/bin/unzip", ["-q", workspace.archive.path, "-d", workspace.content.path])
        let entries = try paths.map { path in
            (path: path, data: try Data(contentsOf: workspace.content.appending(path: path)))
        }
        return try archive(entries)
    }

    private struct Workspace {
        let root: URL
        var content: URL { root.appending(path: "content") }
        var archive: URL { root.appending(path: "archive.zip") }

        init() throws {
            root = FileManager.default.temporaryDirectory.appending(path: "fixturegen-zip-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: root.appending(path: "content"), withIntermediateDirectories: true)
        }

        func remove() { try? FileManager.default.removeItem(at: root) }
    }
}
