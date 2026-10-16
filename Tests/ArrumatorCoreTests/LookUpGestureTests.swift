import ArrumatorCore
import Foundation
import Testing

/// The gestures that open Look Up without a menu (`LookUpGesture`): its panel's Siri Suggestions reach Apple, and the app
/// hands no text to anything outside it (AC 4a of the QA run of 15 October 2026, AGENTS.md §4.1).
@Suite struct LookUpGestureTests {
    /// The key code of the D key on an ANSI keyboard, whatever the layout, and of the E key.
    static let dKey = 2
    static let eKey = 14

    static func key(_ characters: String, _ keyCode: Int, _ modifiers: InputModifiers) -> InputEvent {
        .keyDown(charactersIgnoringModifiers: characters, keyCode: keyCode, modifiers: modifiers)
    }

    @Test func controlCommandDLooksUp() {
        #expect(LookUpGesture.opensLookUp(Self.key("d", Self.dKey, [.control, .command])))
    }

    @Test func theKeyOfDLooksUpUnderAnotherLayout() {
        #expect(LookUpGesture.opensLookUp(Self.key("в", Self.dKey, [.control, .command])), "the Russian layout gives в on the D key")
    }

    @Test func theLetterDLooksUpOnAnotherKey() {
        #expect(LookUpGesture.opensLookUp(Self.key("d", Self.eKey, [.control, .command])), "Dvorak puts D on another key")
    }

    @Test func anotherLetterOnAnotherKeyIsLeftAlone() {
        #expect(!LookUpGesture.opensLookUp(Self.key("в", 9, [.control, .command])), "в on the V key is not the shortcut")
    }

    @Test func capsLockDoesNotHideIt() {
        #expect(LookUpGesture.opensLookUp(Self.key("D", Self.dKey, [.control, .command])), "Caps Lock gives a capital with no Shift held")
    }

    @Test func aForceClickLooksUp() {
        #expect(LookUpGesture.opensLookUp(.pressure(stage: 2)), "the second stage of a press is a force click")
    }

    @Test func aThreeFingerTapLooksUp() {
        #expect(LookUpGesture.opensLookUp(.quickLook))
    }

    @Test(arguments: [
        ("d", [InputModifiers.command]), ("d", [.control]), ("d", []), ("d", [.control, .command, .shift]),
        ("d", [.control, .command, .option]), ("e", [.control, .command]), ("", [.control, .command]),
    ] as [(String, InputModifiers)])
    func otherKeysAreLeftAlone(characters: String, modifiers: InputModifiers) {
        #expect(!LookUpGesture.opensLookUp(Self.key(characters, Self.eKey, modifiers)), "\(characters) with \(modifiers) is typing or another shortcut")
    }

    @Test(arguments: [[InputModifiers.command], [.control], [], [.control, .command, .shift], [.control, .command, .option]])
    func theKeyOfDWithOtherModifiersIsLeftAlone(modifiers: InputModifiers) {
        #expect(!LookUpGesture.opensLookUp(Self.key("в", Self.dKey, modifiers)), "the D key with \(modifiers) is typing or another shortcut")
    }

    @Test(arguments: [0, 1, 3])
    func aLightPressIsLeftAlone(stage: Int) {
        #expect(!LookUpGesture.opensLookUp(.pressure(stage: stage)), "stage \(stage) is an ordinary click or a pressure that has passed")
    }

    @Test func everythingElseIsLeftAlone() {
        #expect(!LookUpGesture.opensLookUp(.other), "a click, a scroll or any other event reaches the app as usual")
    }
}
