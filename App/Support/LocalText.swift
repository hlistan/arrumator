import AppKit
import ArrumatorCore
import SwiftUI

/// The one place no text of the app is handed to anything outside it (AGENTS.md §4.1, AC 4a of the QA run of 15 October
/// 2026). The app processes sensitive documents, so no text it shows or takes, selected or typed, is offered to a web
/// search, Look Up, Translate, Share, Services or Writing Tools. Three parts, each applied once, where a new view cannot
/// miss it:
///
/// - `TextMenuGuard` filters every text menu AppKit draws, by `TextMenuRule`, and the Edit menu.
/// - `keepsTextLocal()` is applied where every window's content is made (`ArrumatorApp.swift`, held there by the `hosting`
///   gate of `scripts/lint.sh`).
/// - `LocalApplication` drops the gestures that open Look Up without a menu (`LookUpGesture`): its panel's Siri Suggestions
///   reach Apple.
///
/// The app has no Services menu, provides no service and declares no `NSServices` (the `local-text` gate of
/// `scripts/lint.sh`). Whether a keyboard shortcut a user gave a service can still reach selected text is not verified
/// (QA charter C14).
///
/// Why this mechanism, and what was and was not seen on macOS 26, is in docs/architecture.md, "Keeping text inside the
/// app". In short: SwiftUI's selectable `Text`, `TextField`, `TextEditor` and the same in a sheet draw their context menu
/// from an `NSMenu` that `NSMenu.didAddItemNotification` reports with no delegate, so it can be given one in time, and
/// "the delegate can change the menu by adding, removing, or modifying menu items" (`NSMenuDelegate.menuNeedsUpdate(_:)`).
/// The items that reach outside have private selectors, hence an allow-list of public ones (`TextMenuRule`), which fails
/// closed. `menuWillOpen(_:)` is not used: "Do not modify the structure of the menu" (NSMenu.h).
@MainActor
final class TextMenuGuard: NSObject, NSMenuDelegate {
    private var observer: (any NSObjectProtocol)?
    private weak var editMenu: NSMenu?
    /// The Edit menu's items as the app made them, which stay; AppKit adds others (AutoFill, Start Dictation, Emoji &
    /// Symbols, and Writing Tools where it is available), which go.
    private var ownEditItems: Set<ObjectIdentifier> = []
    /// The text menus already reported as having a delegate that is not this one.
    private let unfiltered = NSHashTable<NSMenu>.weakObjects()

    /// Makes `main` the app's menu bar and starts guarding every text menu from now on, and the Edit menu `edit` of `main`, as the
    /// app built it. The items the app made are recorded before AppKit has the menu, which adds AutoFill, Start Dictation and
    /// Emoji & Symbols to an Edit menu as it takes it: recorded after, those would be the app's own and never pruned (seen on 16
    /// October 2026). So this is the one place the menu bar is set (gate `main-menu`).
    func install(mainMenu main: NSMenu, editMenu edit: NSMenu) {
        editMenu = edit
        ownEditItems = Set(edit.items.map(ObjectIdentifier.init))
        edit.delegate = self
        NSApp.mainMenu = main
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(forName: NSMenu.didAddItemNotification, object: nil, queue: .main) { [weak self] note in
            // Delivered on the main queue (`queue: .main`), so the menu is only ever touched there.
            nonisolated(unsafe) let menu = note.object as? NSMenu
            MainActor.assumeIsolated { self?.adopt(menu) }
        }
    }

    /// Takes a menu of text as its delegate, the first time it holds a text action, before it is drawn: a context menu has
    /// no supermenu and, so far as AppKit builds it, no delegate; the app's own menus and the main menu's are left alone.
    /// Writing Tools and other apps' contextual menu plug-ins are told not to add their items. A text menu that already has
    /// another delegate cannot be filtered, which is said once for it.
    private func adopt(_ menu: NSMenu?) {
        guard let menu, menu !== NSApp.mainMenu, menu.supermenu == nil, TextMenuRule.isTextMenu(Self.entries(menu)) else { return }
        if let delegate = menu.delegate {
            if delegate !== self { reportForeignDelegate(of: menu, delegate) }
            return
        }
        menu.delegate = self
        menu.automaticallyInsertsWritingToolsItems = false
        menu.allowsContextMenuPlugIns = false
    }

    /// Says once for `menu`, which AppKit tells of each item added to it, that its own delegate leaves its items unfiltered.
    private func reportForeignDelegate(of menu: NSMenu, _ delegate: any NSMenuDelegate) {
        guard !unfiltered.contains(menu) else { return }
        unfiltered.add(menu)
        Log.warning(.ui, "A text menu has a delegate of its own, so its items are not filtered", ["type": String(describing: type(of: delegate))])
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu === editMenu {
            pruneEdit(menu)
        } else if TextMenuRule.isTextMenu(Self.entries(menu)) {
            prune(menu)
        }
    }

    /// Takes out of a text menu, at every depth, whatever `TextMenuRule` does not keep.
    private func prune(_ menu: NSMenu) {
        let entries = Self.entries(menu)
        let kept = Set(TextMenuRule.kept(entries))
        for index in entries.indices.reversed() {
            if !kept.contains(index) {
                menu.removeItem(at: index)
            } else if entries[index].submenu != nil, let submenu = menu.items[index].submenu {
                prune(submenu)
            }
        }
    }

    /// Takes out of the Edit menu what AppKit added, and the separators left first, last or doubled.
    private func pruneEdit(_ menu: NSMenu) {
        let entries = Self.entries(menu)
        let kept = Set(TextMenuRule.separated(entries) { ownEditItems.contains(ObjectIdentifier(menu.items[$0])) })
        for index in entries.indices.reversed() where !kept.contains(index) { menu.removeItem(at: index) }
    }

    /// `menu` as `TextMenuRule` reads it. The Services item, which holds other apps' services under actions that are not on
    /// the allow-list, is left out with them.
    private static func entries(_ menu: NSMenu) -> [MenuEntry] {
        menu.items.map { item in
            item.isSeparatorItem ? MenuEntry(isSeparator: true) : MenuEntry(action: item.action.map(NSStringFromSelector), submenu: item.submenu.map(entries))
        }
    }
}

/// The app's own `NSApplication` (`ArrumatorMain`): it drops, before anything is dispatched, the gestures that open Look Up
/// without a menu, as `LookUpGesture` says (Control-Command-D, a force click, a three-finger tap). Typing, other shortcuts
/// and ordinary clicks reach the app as they always did.
final class LocalApplication: NSApplication {
    override func sendEvent(_ event: NSEvent) {
        guard !LookUpGesture.opensLookUp(event.input) else { return }
        super.sendEvent(event)
    }
}

private extension NSEvent {
    /// This event as `LookUpGesture` reads it. Only a key event has characters and a key code, and only a pressure event a stage.
    var input: InputEvent {
        switch type {
        case .keyDown: .keyDown(charactersIgnoringModifiers: charactersIgnoringModifiers ?? "", keyCode: Int(keyCode), modifiers: InputModifiers(modifierFlags))
        case .pressure: .pressure(stage: Int(stage))
        case .quickLook: .quickLook
        default: .other
        }
    }
}

private extension InputModifiers {
    init(_ flags: NSEvent.ModifierFlags) {
        let held = flags.intersection(.deviceIndependentFlagsMask)
        self = []
        if held.contains(.control) { insert(.control) }
        if held.contains(.command) { insert(.command) }
        if held.contains(.option) { insert(.option) }
        if held.contains(.shift) { insert(.shift) }
    }
}

extension View {
    /// Writing Tools never edits the text of the views below, in the window or a sheet or a popover over it. Applied where
    /// each window's content is made, so every view has it and a new one cannot miss it.
    func keepsTextLocal() -> some View { writingToolsBehavior(.disabled) }
}
