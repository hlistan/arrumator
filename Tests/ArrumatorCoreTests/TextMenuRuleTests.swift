import ArrumatorCore
import Foundation
import Testing

/// What a menu of text may offer (`TextMenuRule`): no text of the app is handed to a search, a service or a tool outside it
/// (AC 4a of the QA run of 15 October 2026, AGENTS.md §4.1).
@Suite struct TextMenuRuleTests {
    static func item(_ action: String) -> MenuEntry { MenuEntry(action: action) }
    static let separator = MenuEntry(isSeparator: true)

    @Test func aTextMenuKeepsEditingSpellingSubstitutionsAndSpeech() {
        let spelling = MenuEntry(submenu: [Self.item("showGuessPanel:"), Self.item("checkSpelling:"), Self.item("toggleContinuousSpellChecking:")])
        let substitutions = MenuEntry(submenu: [Self.item("toggleSmartInsertDelete:"), Self.item("toggleAutomaticQuoteSubstitution:")])
        let speech = MenuEntry(submenu: [Self.item("startSpeaking:"), Self.item("stopSpeaking:")])
        let menu = [Self.item("cut:"), Self.item("copy:"), Self.item("paste:"), Self.item("pasteAsPlainText:"), Self.separator,
                    spelling, substitutions, speech, Self.separator, Self.item("selectAll:")]
        #expect(TextMenuRule.kept(menu) == Array(menu.indices), "every one of them stays, with the separators between")
        #expect(TextMenuRule.isTextMenu(menu), "and it is a menu of text")
    }

    /// Every selector the allow-list keeps, written out here and not read from `TextMenuRule.kept`, so that adding or taking one
    /// away is a decision the test shows (AGENTS.md §3: each value of a set is tested).
    static let allowed = [
        "cut:", "copy:", "paste:", "selectAll:", "pasteAsPlainText:", "delete:", "undo:", "redo:",
        "showGuessPanel:", "checkSpelling:", "toggleContinuousSpellChecking:", "toggleGrammarChecking:",
        "toggleAutomaticSpellingCorrection:", "changeSpelling:", "ignoreSpelling:",
        "orderFrontSubstitutionsPanel:", "toggleSmartInsertDelete:", "toggleAutomaticQuoteSubstitution:",
        "toggleAutomaticDashSubstitution:", "toggleAutomaticTextReplacement:", "toggleAutomaticLinkDetection:",
        "toggleAutomaticDataDetection:", "toggleAutomaticTextCompletion:",
        "uppercaseWord:", "lowercaseWord:", "capitalizeWord:",
        "startSpeaking:", "stopSpeaking:",
        "orderFrontFontPanel:", "changeLayoutOrientation:",
    ]

    @Test(arguments: allowed)
    func aTextMenuKeepsEveryAllowedAction(action: String) {
        let menu = [Self.item("_translate:"), Self.item(action), Self.item("_share:")]
        #expect(TextMenuRule.kept(menu) == [1], "\(action) stays, and what is around it goes")
    }

    @Test func theAllowListIsExactlyWhatIsWrittenHere() {
        #expect(TextMenuRule.kept == Set(Self.allowed), "an action added to or taken off the allow-list is added here too")
        #expect(Self.allowed.count == Set(Self.allowed).count, "none is written twice")
    }

    @Test(arguments: ["_lookUpDefinitionFromMenu:", "_translate:", "_searchWithGoogleFromMenu:", "showWritingTools:", "_shareFromMenu:",
                      "anyFutureAction:"])
    func aTextMenuDropsEveryOtherAction(action: String) {
        let menu = [Self.item("copy:"), Self.separator, Self.item(action), Self.item("paste:")]
        #expect(TextMenuRule.kept(menu) == [0, 1, 3], "\(action) goes, with nothing but the allow-list to say so, and the rest stays")
        #expect(!TextMenuRule.kept.contains(action), "it is not on the allow-list")
    }

    @Test func aSubmenuLeftEmptyIsDropped() {
        let translate = MenuEntry(submenu: [Self.item("_translateSelection:"), Self.item("_lookUp:")])
        let none = MenuEntry(submenu: [])
        #expect(TextMenuRule.kept([Self.item("copy:"), translate, none]) == [0], "a submenu with nothing kept in it goes, and so does an empty one")
        let nested = MenuEntry(submenu: [MenuEntry(submenu: [Self.item("checkSpelling:")])])
        #expect(TextMenuRule.kept([nested]) == [0], "a submenu that holds one that is kept is kept")
    }

    @Test func theServicesItemIsDropped() {
        // AppKit gives the Services item no action, and its submenu is the system's list of services, never read.
        let services = MenuEntry(action: nil, isSeparator: false, submenu: nil)
        #expect(TextMenuRule.kept([Self.item("copy:"), services, Self.item("paste:")]) == [0, 2], "an item that does nothing and opens nothing known goes")
        let listed = MenuEntry(submenu: [Self.item("_performService:")])
        #expect(TextMenuRule.kept([Self.item("copy:"), listed]) == [0], "and so does one whose services are listed")
    }

    @Test func separatorsAreNeitherFirstLastNorDoubled() {
        let menu = [Self.separator, Self.item("_translate:"), Self.separator, Self.item("copy:"), Self.separator, Self.item("_share:"),
                    Self.separator, Self.item("paste:"), Self.separator]
        let kept = TextMenuRule.kept(menu)
        #expect(kept.map { menu[$0] } == [Self.item("copy:"), Self.separator, Self.item("paste:")] && kept == [3, 6, 7],
                "one separator between what is kept, none at either end: \(kept)")
        #expect(TextMenuRule.kept([Self.separator, Self.separator]).isEmpty, "separators alone leave nothing")
        #expect(TextMenuRule.kept([Self.item("copy:"), Self.separator, Self.separator, Self.item("paste:")]) == [0, 2, 3],
                "doubled ones are one")
    }

    @Test func aMenuWithoutTextActionsIsNotATextMenu() {
        let row = [Self.item("moveToTrash:"), Self.separator, Self.item("showInFinder:")]
        #expect(!TextMenuRule.isTextMenu(row), "a row's own menu, Move to Trash… among it, is the app's and is left alone")
        #expect(TextMenuRule.isTextMenu([MenuEntry(submenu: [Self.item("selectAll:")])]), "a text action within a submenu makes it one")
    }

    @Test func separatorsAreSettledAroundWhateverIsWanted() {
        // The Edit menu keeps what the app made and drops what AppKit added, which is not decided by an action.
        let menu = [Self.item("undo:"), Self.separator, Self.item("addedByAppKit:"), Self.separator, Self.item("cut:"), Self.separator,
                    Self.item("addedToo:"), Self.separator]
        let ownOnes: Set<Int> = [0, 4]
        #expect(TextMenuRule.separated(menu) { ownOnes.contains($0) } == [0, 3, 4], "the separator before the wanted entry stays, the others go")
        #expect(TextMenuRule.separated(menu) { _ in false }.isEmpty, "nothing wanted leaves nothing, separators included")
    }
}
