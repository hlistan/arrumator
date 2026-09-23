import AppKit
import ArrumatorCore
import QuickLookThumbnailing
import ServiceManagement
import SwiftUI

/// A Quick Look thumbnail of a file, or its Finder icon while there is none.
struct FileThumbnail: View {
    let url: URL
    let size: CGSize
    @Environment(\.displayScale) private var scale
    @State private var image: NSImage?

    var body: some View {
        Image(nsImage: image ?? NSWorkspace.shared.icon(forFile: url.path))
            .resizable()
            .scaledToFit()
            .frame(width: size.width, height: size.height)
            .task(id: url) {
                let request = QLThumbnailGenerator.Request(fileAt: url, size: size, scale: scale, representationTypes: .thumbnail)
                // A file type without a thumbnail keeps its icon.
                image = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request).nsImage
            }
    }
}

/// Launch at login via the modern login-item API (explicit user choice, off by default).
enum LoginItem {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    static func set(_ enabled: Bool) throws {
        if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
    }
}

/// Folder picker.
enum FolderPicker {
    static func choose(title: String, startingAt path: String?) -> String? {
        let panel = NSOpenPanel()
        panel.title = title
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        if let path { panel.directoryURL = URL(fileURLWithPath: path.expandingTilde) }
        return panel.runModal() == .OK ? panel.url?.path : nil
    }
}

extension Text {
    /// Renders search snippets with matched terms emphasised.
    init(highlighted snippet: String) {
        var attributed = AttributedString()
        for (segment, isMatch) in SearchHighlight.runs(snippet) {
            var part = AttributedString(segment)
            if isMatch {
                part.inlinePresentationIntent = .stronglyEmphasized
                part.backgroundColor = .yellow.opacity(0.35)
            }
            attributed += part
        }
        self.init(attributed)
    }
}

