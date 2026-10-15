import Foundation

/// The modifier keys of an input event that decide a shortcut; Caps Lock, the Fn key and the like do not.
public struct InputModifiers: OptionSet, Sendable, Hashable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let control = InputModifiers(rawValue: 1 << 0)
    public static let command = InputModifiers(rawValue: 1 << 1)
    public static let option = InputModifiers(rawValue: 1 << 2)
    public static let shift = InputModifiers(rawValue: 1 << 3)
}

/// An input event as `LookUpGesture` reads it from AppKit's `NSEvent`: only what tells a Look Up gesture from anything
/// else. A pure value, so the rule needs no AppKit.
public enum InputEvent: Sendable, Hashable {
    /// `keyCode` is the physical key (`NSEvent.keyCode`), which no layout changes.
    case keyDown(charactersIgnoringModifiers: String, keyCode: Int, modifiers: InputModifiers)
    /// A change in the pressure of a click, as `NSEvent.stage` numbers it.
    case pressure(stage: Int)
    /// The three-finger tap (`NSEvent.EventType.quickLook`).
    case quickLook
    case other
}

/// The ways to Look Up the selected text that need no menu, which `LocalApplication` drops (App/Support/LocalText.swift).
/// The Look Up panel's Siri Suggestions reach Apple, and the app hands no text to anything outside it (AGENTS.md §4.1),
/// so the menu item is not enough: Control-Command-D (`quickLookPreviewItems:` falls back to the dictionary), a force
/// click and a three-finger tap each open it.
public enum LookUpGesture {
    /// The key of the shortcut, with Control and Command held and nothing else: the letter D, or the key that is D on an
    /// ANSI keyboard (`kVK_ANSI_D`), as under the Russian layout the letter is "в" and the shortcut stays on that key.
    public static let shortcutKey = "d"
    public static let shortcutKeyCode = 2
    public static let shortcutModifiers: InputModifiers = [.control, .command]
    /// The stage of a press that is a force click; stage 1 is an ordinary click.
    public static let forceClickStage = 2

    /// Whether `event` asks to Look Up something, and so is never delivered.
    public static func opensLookUp(_ event: InputEvent) -> Bool {
        switch event {
        case let .keyDown(characters, keyCode, modifiers):
            modifiers == shortcutModifiers && (characters.lowercased() == shortcutKey || keyCode == shortcutKeyCode)
        case let .pressure(stage): stage == forceClickStage
        case .quickLook: true
        case .other: false
        }
    }
}
