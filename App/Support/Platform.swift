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

    /// Whether macOS launched the app as its login item. The open-application Apple event it launches the app with then
    /// carries `keyAELaunchedAsLogInItem` as its `keyAEPropData` ("if present in a kAEOpenApplication event, the
    /// receiving application was launched as a login item and should only perform actions suitable to that
    /// environment": https://developer.apple.com/documentation/coreservices/keyaelaunchedasloginitem). The event is
    /// `NSAppleEventManager.currentAppleEvent` only while it is handled, and AppKit calls
    /// `applicationDidFinishLaunching(_:)` then, so this is read there, as LaunchAtLogin-Modern does for the same
    /// `SMAppService.mainApp` login item (https://github.com/sindresorhus/LaunchAtLogin-Modern).
    /// `NSApplication.launchIsDefaultUserInfoKey` cannot tell: it is false too when the app is launched to open a file or
    /// to restore saved state, as the user may launch it.
    static var launchedTheApp: Bool {
        guard let event = NSAppleEventManager.shared().currentAppleEvent else { return false }
        return event.eventID == kAEOpenApplication
            && event.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
    }

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
