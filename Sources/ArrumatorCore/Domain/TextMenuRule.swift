import Foundation

/// One entry of a menu, as the App's text-menu guard (`TextMenuGuard`) reads it from AppKit: what it sends, whether it is a
/// separator, and what it opens. A pure value, so the rule below needs no AppKit.
public struct MenuEntry: Sendable, Hashable {
    /// The selector the entry sends, by name ("copy:"); nil for a separator and for an item that only opens a submenu.
    public var action: String?
    public var isSeparator: Bool
    /// What the entry opens; nil for an entry that opens nothing, and for a Services item, whose submenu is the system's
    /// list of other apps' services and is never read.
    public var submenu: [MenuEntry]?

    public init(action: String? = nil, isSeparator: Bool = false, submenu: [MenuEntry]? = nil) {
        self.action = action
        self.isSeparator = isSeparator
        self.submenu = submenu
    }
}

/// What a menu of text may offer. The app processes sensitive documents, so no text in it, selected or typed, is handed to
/// an outside search, service or tool (AGENTS.md §4.1): no web search, Look Up, Translate, Share, Services, or Writing
/// Tools. This is an allow-list, so it fails closed: the items AppKit adds on its own, whose selectors are private and
/// change with each macOS, are dropped without anyone naming them, and a new one leaks nothing. `kept` lists only public
/// selectors, found in the macOS SDK headers (NSText.h, NSTextView.h, NSResponder.h, NSSpellProtocol.h, NSFontManager.h).
/// Which of them were seen in a menu and which are taken from the headers, and why only public ones, is in
/// docs/architecture.md, "Keeping text inside the app".
public enum TextMenuRule {
    /// The actions that make a menu one of text: only a text view's menu sends these.
    public static let textActions: Set<String> = ["cut:", "copy:", "paste:", "selectAll:"]

    /// The actions a menu of text keeps: editing, spelling and grammar, substitutions, transformations and speech, all done
    /// on this Mac, and the font and layout panels.
    public static let kept: Set<String> = textActions.union([
        "pasteAsPlainText:", "delete:", "undo:", "redo:",
        "showGuessPanel:", "checkSpelling:", "toggleContinuousSpellChecking:", "toggleGrammarChecking:",
        "toggleAutomaticSpellingCorrection:", "changeSpelling:", "ignoreSpelling:",
        "orderFrontSubstitutionsPanel:", "toggleSmartInsertDelete:", "toggleAutomaticQuoteSubstitution:",
        "toggleAutomaticDashSubstitution:", "toggleAutomaticTextReplacement:", "toggleAutomaticLinkDetection:",
        "toggleAutomaticDataDetection:", "toggleAutomaticTextCompletion:",
        "uppercaseWord:", "lowercaseWord:", "capitalizeWord:",
        "startSpeaking:", "stopSpeaking:",
        "orderFrontFontPanel:", "changeLayoutOrientation:",
    ])

    /// Whether `entries` are a menu of text, at any depth: some entry sends one of `textActions`. The app's own menus, such
    /// as a row's, never do, and are left as they are.
    public static func isTextMenu(_ entries: [MenuEntry]) -> Bool {
        entries.contains { entry in
            entry.action.map(textActions.contains) == true || entry.submenu.map(isTextMenu) == true
        }
    }

    /// The positions of `entries` to keep, in order: an action in `kept`, a submenu with something kept in it, and the
    /// separators between what is kept, none first, last or doubled. Anything else goes, a Services item among it.
    public static func kept(_ entries: [MenuEntry]) -> [Int] {
        separated(entries) { keeps(entries[$0]) }
    }

    /// The positions of `entries` to keep, in order: those `wanted` says, and the separators between them, none first,
    /// last or doubled. Every separator in `entries` goes unless it is the last one before a wanted entry that follows
    /// another.
    public static func separated(_ entries: [MenuEntry], wanted: (Int) -> Bool) -> [Int] {
        var indices: [Int] = []
        var separatorPending = false
        for (index, entry) in entries.enumerated() {
            if entry.isSeparator {
                separatorPending = !indices.isEmpty
                continue
            }
            guard wanted(index) else { continue }
            if separatorPending, let separator = entries[..<index].lastIndex(where: \.isSeparator) { indices.append(separator) }
            separatorPending = false
            indices.append(index)
        }
        return indices
    }

    private static func keeps(_ entry: MenuEntry) -> Bool {
        if let submenu = entry.submenu { return !kept(submenu).isEmpty }
        return entry.action.map(kept.contains) == true
    }
}
