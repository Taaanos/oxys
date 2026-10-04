import AppKit
import Testing
@testable import Commands

@MainActor private let ascii = KeyLayout.installed(id: "com.apple.keylayout.ABC") ?? KeyLayout.installed(id: "com.apple.keylayout.US")

private func input(_ key: PhysicalKey, _ mods: KeyModifiers = [], character: Character? = nil, down: Bool = true) -> KeyInput {
    KeyInput(keyCode: key.rawValue, modifiers: mods, isDown: down, timestamp: 0, character: character)
}

@Test func lettersDigitsAndArrowsBindByPosition() {
    #expect(Shortcut.capture(input(.x, character: "x")) == .shortcut(Shortcut(.position(.x))))
    #expect(Shortcut.capture(input(.digit3, [.shift], character: "#")) == .shortcut(Shortcut(.position(.digit3), [.shift])))
    #expect(Shortcut.capture(input(.rightArrow, [.option])) == .shortcut(Shortcut(.position(.rightArrow), [.option])))
    #expect(Shortcut.capture(input(.e, [.command, .shift], character: "E")) == .shortcut(Shortcut(.position(.e), [.command, .shift])))
}

@Test func barePunctuationBindsByTheCharacterItTypes() {
    #expect(Shortcut.capture(input(.leftBracket, character: "[")) == .shortcut(Shortcut(.character("["))))
    #expect(Shortcut.capture(input(.equal, character: "=")) == .shortcut(Shortcut(.character("="))))
    // `?` is `⇧/` on a US keyboard; the character already holds the `⇧`, so the file names no modifier.
    #expect(Shortcut.capture(input(.slash, [.shift], character: "?")) == .shortcut(Shortcut(.character("?"))))
    #expect(Shortcut.capture(input(.leftBracket, [.shift], character: "{")) == .shortcut(Shortcut(.character("{"))))
}

@Test func punctuationWithCommandControlOrOptionKeepsItsPosition() {
    #expect(Shortcut.capture(input(.equal, [.command], character: "=")) == .shortcut(Shortcut(.position(.equal), [.command])))
    #expect(Shortcut.capture(input(.equal, [.command, .shift], character: "+")) == .shortcut(Shortcut(.position(.equal), [.command, .shift])))
    #expect(Shortcut.capture(input(.leftBracket, [.option], character: "“")) == .shortcut(Shortcut(.position(.leftBracket), [.option])))
    #expect(Shortcut.capture(input(.slash, [.control], character: "/")) == .shortcut(Shortcut(.position(.slash), [.control])))
}

@Test func punctuationWithNoKnownCharacterFallsBackToThePosition() {
    #expect(Shortcut.capture(input(.comma, character: nil)) == .shortcut(Shortcut(.position(.comma))))
}

@Test func bareEscapeCancelsAndEscapeWithAModifierIsAKey() {
    #expect(Shortcut.capture(input(.escape)) == .cancel)
    #expect(Shortcut.capture(input(.escape, [.shift])) == .shortcut(Shortcut(.position(.escape), [.shift])))
}

@Test func keysWithoutANameAndKeyUpsAreUnsupported() {
    #expect(Shortcut.capture(KeyInput(keyCode: 200, timestamp: 0)) == .unsupported)
    #expect(Shortcut.capture(input(.x, down: false)) == .unsupported)
}

@Test func functionAndPageKeysAreKeys() {
    #expect(Shortcut.capture(input(.f5)) == .shortcut(Shortcut(.position(.f5))))
    #expect(Shortcut.capture(input(.pageDown, [.shift])) == .shortcut(Shortcut(.position(.pageDown), [.shift])))
    #expect(Shortcut.capture(input(.forwardDelete)) == .shortcut(Shortcut(.position(.forwardDelete))))
}

@MainActor @Test(arguments: ["com.apple.keylayout.Greek", "com.apple.keylayout.Russian"])
func aNonLatinLayoutRecordsTheSameShortcutsAsTheLatinOne(id: String) throws {
    let layout = try #require(KeyLayout.installed(id: id))
    let latin = try #require(ascii)
    #expect(layout.typesLatin == false)
    for (key, mods) in [(PhysicalKey.x, KeyModifiers()), (.digit3, [.shift]), (.e, [.command]), (.leftBracket, []), (.slash, [.shift]), (.equal, [.command])] as [(PhysicalKey, KeyModifiers)] {
        var flags: NSEvent.ModifierFlags = []
        if mods.contains(.shift) { flags.insert(.shift) }
        if mods.contains(.command) { flags.insert(.command) }
        // What the system delivers: this layout's characters, this key's code. The app asks the Latin layout.
        let typed = layout.character(keyCode: key.rawValue, shift: mods.contains(.shift)).map(String.init) ?? ""
        let event = try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil,
            characters: typed, charactersIgnoringModifiers: typed, isARepeat: false, keyCode: key.rawValue))
        let underLayout = try #require(KeyInput(event: event, layout: latin))
        let underLatin = KeyInput(keyCode: key.rawValue, modifiers: mods, timestamp: 0,
                                  character: latin.character(keyCode: key.rawValue, shift: mods.contains(.shift)))
        #expect(Shortcut.capture(underLayout) == Shortcut.capture(underLatin))
        #expect(Shortcut.capture(underLayout) != .unsupported)
    }
}

@Test func theRecordedKeyRoutesTheCommandItWasRecordedFor() {
    // Record `[` for Reject, resolve, and route a press of that key.
    var editor = KeymapEditor()
    guard case .shortcut(let shortcut) = Shortcut.capture(input(.leftBracket, character: "[")) else { Issue.record("no shortcut"); return }
    // `[` is Decrease Rating's key: the editor says so before anything is saved.
    #expect(editor.check(shortcut, for: "cull.reject") == .conflicts([
        KeyConflict(command: "cull.rate.down", title: "Decrease Rating", modes: [.grid, .loupe, .compare],
                    shortcut: shortcut, isShiftTwin: false),
    ]))
    editor.assign(shortcut, to: "cull.reject", reassign: true)
    var router = KeyRouter(keymap: editor.resolved.keymap)
    let hit = router.handle(KeyInput(keyCode: PhysicalKey.leftBracket.rawValue, timestamp: 0, character: "["), mode: .loupe, focus: .canvas)
    #expect(hit.actions == [.perform("cull.reject")])
}

@Test func reservedKeysNameTheirOwner() {
    #expect(ReservedShortcuts.reason(for: Shortcut(.position(.q), [.command]), modes: []) != nil)
    #expect(ReservedShortcuts.reason(for: Shortcut(.character("?"), [.command]), modes: []) != nil)
    #expect(ReservedShortcuts.reason(for: Shortcut(.position(.q)), modes: []) == nil)
    #expect(ReservedShortcuts.reason(for: Shortcut(.position(.space)), modes: [.loupe]) != nil)
    #expect(ReservedShortcuts.reason(for: Shortcut(.position(.space)), modes: []) != nil)
    #expect(ReservedShortcuts.reason(for: Shortcut(.position(.space)), modes: [.grid, .compare]) == nil)
}

@Test func noDefaultKeyIsReserved() {
    for b in CommandTable.standard.defaultBindings {
        #expect(ReservedShortcuts.reason(for: Shortcut(b.key, b.modifiers), modes: b.modes) == nil, "\(b.command.rawValue)")
    }
}

@MainActor @Test func theKeypadAndTheDigitRowAreLabelledApart() {
    #expect(KeyLabels.label(for: .position(.keypad3)) == "Keypad 3")
    #expect(KeyLabels.label(for: .position(.digit3)) != KeyLabels.label(for: .position(.keypad3)))
    #expect(KeyLabels.label(for: .position(.f5)) == "F5")
    #expect(KeyLabels.label(for: Shortcut(.position(.pageDown), [.shift])) == "⇧Page Down")
}
