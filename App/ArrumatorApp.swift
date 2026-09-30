import AppKit
import ArrumatorCore
import SwiftUI

/// AppKit shell: an explicit status item (SwiftUI status items proved unreliable here, and a full menu bar can hide
/// them), a Dock icon by default so the app is always reachable, and windows hosting the SwiftUI views.
@main
enum ArrumatorMain {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}

enum WindowID: String {
    case main, onboarding, settings

    var title: String { Wording.title(of: self) }

    var size: NSSize {
        switch self {
        case .main: Style.mainWindow
        case .onboarding: Style.onboardingWindow
        case .settings: Style.settingsWindow
        }
    }
}

@MainActor
protocol WindowPresenting: AnyObject {
    func show(_ id: WindowID)
    func close(_ id: WindowID)
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, WindowPresenting {
    private let model = AppModel()
    private var statusItem: NSStatusItem?
    private let popover = NSPopover()
    private var windows: [WindowID: NSWindow] = [:]
    /// False when macOS started the app by itself, such as a login item; then no window is opened unasked.
    private var openedByUser = true

    func applicationDidFinishLaunching(_ notification: Notification) {
        openedByUser = notification.userInfo?[NSApplication.launchIsDefaultUserInfoKey] as? Bool ?? true
        model.presenter = self
        NSApp.mainMenu = MainMenu.build()
        installStatusItem()
        Task {
            await model.start()
            applyDockPolicy()
            reportStatusItem()
            if model.settings?.onboardingCompleted != true {
                show(.onboarding)
            } else if openedByUser {
                show(.main)
            }
            trackModel()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// Clicking the Dock icon (or opening the app again) brings the window back, once the model knows which one.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows, model.phase == .ready {
            show(model.settings?.onboardingCompleted == true ? .main : .onboarding)
        }
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        let runtime = model.runtime
        Task { await runtime?.stop() }
    }

    // MARK: Status item

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: model.statusSymbol, accessibilityDescription: Wording.appName)
        item.button?.imagePosition = .imageLeading
        item.button?.target = self
        item.button?.action = #selector(togglePopover)
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        item.behavior = .terminationOnRemoval
        statusItem = item
        popover.behavior = .transient
        popover.contentSize = Style.popover
        popover.contentViewController = NSHostingController(rootView: MenuBarView().environment(model))
    }

    /// Records whether the icon is actually on screen: a full menu bar silently clips status items, and then the
    /// Dock icon is the only way in.
    private func reportStatusItem() {
        guard let item = statusItem, let window = item.button?.window else {
            Log.warning(.ui, "Menu bar icon could not be created")
            return
        }
        let screen = NSScreen.main?.frame.width ?? 0
        let clipped = window.frame.origin.x <= 0 || window.frame.maxX > screen
        model.menuBarIconHidden = clipped
        Log.log(clipped ? .warning : .info, .ui, clipped ? "Menu bar icon is hidden: the menu bar is full" : "Menu bar icon shown", [
            "visible": String(item.isVisible), "x": String(Int(window.frame.origin.x)), "width": String(Int(window.frame.width)),
            "screen": String(Int(screen)),
        ])
    }

    @objc private func togglePopover() {
        guard let button = statusItem?.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            NSApp.activate()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .maxY)
        }
    }

    /// Redraws the status icon and Dock policy whenever the model changes.
    private func trackModel() {
        withObservationTracking {
            _ = model.statusSymbol
            _ = model.reviewCount
            _ = model.settings?.showInDock
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.statusItem?.button?.image = NSImage(systemSymbolName: self.model.statusSymbol,
                                                         accessibilityDescription: Wording.appName)
                self.statusItem?.button?.title = self.model.reviewCount > 0 ? Wording.statusItemCount(self.model.reviewCount) : ""
                self.applyDockPolicy()
                self.trackModel()
            }
        }
    }

    private func applyDockPolicy() {
        let wanted: NSApplication.ActivationPolicy = model.settings?.showInDock == true ? .regular : .accessory
        if NSApp.activationPolicy() != wanted { NSApp.setActivationPolicy(wanted) }
    }

    // MARK: Windows

    func show(_ id: WindowID) {
        if let existing = windows[id] {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate()
            return
        }
        let content: AnyView = switch id {
        case .main: AnyView(MainWindow())
        case .onboarding: AnyView(OnboardingView())
        case .settings: AnyView(SettingsView())
        }
        let window = NSWindow(contentViewController: NSHostingController(rootView: content.environment(model)))
        window.title = id.title
        window.identifier = NSUserInterfaceItemIdentifier(id.rawValue)
        window.setContentSize(id.size)
        window.styleMask.insert(.miniaturizable)
        if id == .main {
            window.styleMask.insert(.resizable)
            window.contentMinSize = Style.mainWindowMinimum
        }
        window.center()
        window.setFrameAutosaveName("arrumator.\(id.rawValue)")
        window.isReleasedWhenClosed = false
        window.delegate = self
        windows[id] = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        Log.info(.ui, "Opened window", ["window": id.rawValue])
    }

    func close(_ id: WindowID) {
        windows[id]?.close()
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, let raw = window.identifier?.rawValue,
              let id = WindowID(rawValue: raw) else { return }
        windows[id] = nil
    }
}

/// The standard macOS menus: without them a Dock app has no Edit menu, so text fields lose cut, copy and paste.
enum MainMenu {
    static func build() -> NSMenu {
        let main = NSMenu()
        let appItem = NSMenuItem()
        let app = NSMenu()
        app.addItem(withTitle: Wording.aboutApp, action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        app.addItem(.separator())
        app.addItem(item(Wording.settings, #selector(AppCommands.showSettings), ","))
        app.addItem(.separator())
        app.addItem(withTitle: Wording.hideApp, action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        app.addItem(withTitle: Wording.quitApp, action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = app
        main.addItem(appItem)

        let windowItem = NSMenuItem()
        let window = NSMenu(title: Wording.windowMenu)
        window.addItem(item(Wording.appName, #selector(AppCommands.showMain), "0"))
        window.addItem(item(Wording.setup, #selector(AppCommands.showOnboarding), ""))
        window.addItem(.separator())
        window.addItem(withTitle: Wording.minimise, action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        window.addItem(withTitle: Wording.close, action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowItem.submenu = window
        main.addItem(windowItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: Wording.editMenu)
        edit.addItem(withTitle: Wording.undo, action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: Wording.redo, action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: Wording.cut, action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: Wording.copy, action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: Wording.paste, action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: Wording.selectAll, action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)
        return main
    }

    private static func item(_ title: String, _ action: Selector, _ key: String) -> NSMenuItem {
        NSMenuItem(title: title, action: action, keyEquivalent: key)
    }
}

/// Menu actions travel the responder chain to the application delegate.
@objc protocol AppCommands {
    func showMain()
    func showOnboarding()
    func showSettings()
}

extension AppDelegate: AppCommands {
    @objc func showMain() { show(.main) }
    @objc func showOnboarding() { show(.onboarding) }
    @objc func showSettings() { show(.settings) }
}
