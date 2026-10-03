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
    /// True when macOS started the app by itself, as a login item; then no window is opened unasked.
    private var launchedAsLoginItem = false
    /// True once quitting has begun stopping the app's work.
    private var quitting = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        launchedAsLoginItem = LoginItem.launchedTheApp
        model.presenter = self
        NSApp.mainMenu = MainMenu.build()
        installStatusItem()
        Task {
            await model.start()
            applyDockPolicy()
            reportStatusItem()
            if case .failed = model.phase {
                // Why the app could not start, such as settings it cannot run with, with the file and what mends it, is
                // on the main window's first page: never onboarding, which would ask again for what is set.
                show(.main)
            } else if model.settings?.onboardingCompleted != true {
                show(.onboarding)
            } else if !launchedAsLoginItem {
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

    /// Quitting stops the app's work first, so the document in hand stops where it carries on at the next start instead
    /// of being cut off wherever the process ends. `applicationWillTerminate(_:)` is too late for that: the process ends
    /// as soon as it returns, before any work it starts has run. AppKit lets the delegate finish work first: "If the
    /// method returns NSApplication.TerminateReply.terminateLater, the app runs its run loop in the modalPanel mode until
    /// the reply(toApplicationShouldTerminate:) method is called with the value true or false" (`NSApplication.terminate(_:)`).
    /// The main actor's work goes on meanwhile: the run loop serves the main queue in its common modes (CFRunLoop.c), and
    /// "in Cocoa applications, this set includes the default, modal, and event tracking modes" (Threading Programming
    /// Guide › Run Loops › Run Loop Modes). The wait is bounded (`ArrumatorRuntime.stopBeforeQuitting()`,
    /// `ingest.quitTimeout`), so a stop that hangs keeps neither the app from quitting nor the Mac from logging out, and
    /// the Ollama server the app started ends with it either way. Every way to quit comes here, the Quit of the menu bar
    /// popover included, which only asks AppKit to terminate; nothing else in the app stops the runtime (quit gate in
    /// `scripts/lint.sh`).
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let runtime = model.runtime else { return .terminateNow }
        guard !quitting else { return .terminateLater }
        quitting = true
        Task {
            await runtime.stopBeforeQuitting()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
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

    /// Opens a window, or brings back the one already open, in front of every app's windows: every window the app shows
    /// comes through here. While the app is not active, `makeKeyAndOrderFront` puts a window in front of this app's
    /// windows only ("normally an NSWindow object can't be moved in front of the key window unless it and the key
    /// window are in the same application", `NSWindow.orderFrontRegardless()`), and since macOS 14 activation is a
    /// request the system may decline ("calling this method doesn't guarantee app activation", `NSApplication.activate()`;
    /// AppKit Release Notes for macOS 14 › App activation). Launched as an accessory (`LSUIElement`) from a terminal, the
    /// app was not made active, and its main window opened behind the terminal's. `orderFrontRegardless()` "moves the
    /// window to the front of its level, even if its application isn't active"; the window is already key, so it takes
    /// the keyboard as soon as macOS lets the app become active, at once or at the user's first click in it.
    func show(_ id: WindowID) {
        let window = windows[id] ?? makeWindow(id)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        NSApp.activate()
    }

    private func makeWindow(_ id: WindowID) -> NSWindow {
        let content: AnyView = switch id {
        // The view's own minimum too: the hosting controller sets the window's minimum from its view's.
        case .main: AnyView(MainWindow().frame(minWidth: Style.mainWindowMinimum.width, minHeight: Style.mainWindowMinimum.height))
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
        // A frame saved smaller than the minimum, by an earlier version or a script, is not restored as it was.
        if id == .main {
            let content = window.contentRect(forFrameRect: window.frame).size
            if content.width < Style.mainWindowMinimum.width || content.height < Style.mainWindowMinimum.height {
                window.setContentSize(CGSize(width: max(content.width, Style.mainWindowMinimum.width),
                                             height: max(content.height, Style.mainWindowMinimum.height)))
            }
        }
        window.isReleasedWhenClosed = false
        window.delegate = self
        windows[id] = window
        Log.info(.ui, "Opened window", ["window": id.rawValue])
        return window
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
        app.addItem(item(Wording.settings, #selector((any AppCommands).showSettings), ","))
        app.addItem(.separator())
        app.addItem(withTitle: Wording.hideApp, action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        app.addItem(withTitle: Wording.quitApp, action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = app
        main.addItem(appItem)

        let windowItem = NSMenuItem()
        let window = NSMenu(title: Wording.windowMenu)
        window.addItem(item(Wording.appName, #selector((any AppCommands).showMain), "0"))
        window.addItem(item(Wording.setup, #selector((any AppCommands).showOnboarding), ""))
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
