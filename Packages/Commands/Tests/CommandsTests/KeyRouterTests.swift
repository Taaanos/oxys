import AppKit
import Testing
@testable import Commands

@MainActor private let ascii = KeyLayout.installed(id: "com.apple.keylayout.ABC") ?? KeyLayout.installed(id: "com.apple.keylayout.US")

/// The PRD's default bindings that F-05 must route, as data.
private let keymap = Keymap([
    .init(.position(.x), command: "cull.reject"),
    .init(.position(.digit3), command: "cull.rate3"),
    .init(.position(.digit3), [.shift], command: "cull.rate3.advance"),
    .init(.position(.z), command: "view.zoom", behavior: .toggleOrHold),
    .init(.position(.rightArrow), command: "nav.next", behavior: .repeating),
    .init(.position(.escape), modes: [.loupe, .compare], command: "nav.grid"),
    .init(.position(.a), [.command], command: "select.all"),
    .init(.position(.r), [.command], command: "file.reveal"),
    .init(.position(.z), [.command], command: "edit.undo"),
    .init(.character("["), command: "rate.down"),
    .init(.character("]"), command: "rate.up"),
    .init(.character("\\"), command: "cull.clear"),
    .init(.character("="), command: "zoom.in"),
    .init(.character("-"), command: "zoom.out"),
    .init(.character("?"), command: "help.cheatsheet"),
])

@MainActor private func key(_ k: PhysicalKey, _ mods: KeyModifiers = [], down: Bool = true, rep: Bool = false,
                 t: Double = 0, layout: KeyLayout? = ascii) -> KeyInput {
    KeyInput(keyCode: k.rawValue, modifiers: mods, isDown: down, isRepeat: rep, timestamp: t,
             character: layout?.character(keyCode: k.rawValue, shift: mods.contains(.shift), option: mods.contains(.option)))
}

private func route(_ router: inout KeyRouter, _ input: KeyInput, mode: ViewMode = .loupe,
                   focus: KeyFocus = .canvas) -> RoutingResult {
    router.handle(input, mode: mode, focus: focus)
}

@MainActor @Test func positionalKeysRouteRegardlessOfTypedCharacter() {
    // Under Greek input `X` types χ; routing never looks at that.
    var router = KeyRouter(keymap: keymap)
    let greekX = KeyInput(keyCode: PhysicalKey.x.rawValue, timestamp: 0, character: "χ")
    #expect(route(&router, greekX).actions == [.perform("cull.reject")])
    let cyrillic3 = KeyInput(keyCode: PhysicalKey.digit3.rawValue, timestamp: 1, character: "3")
    #expect(route(&router, cyrillic3).actions == [.perform("cull.rate3")])
}

@MainActor @Test func commandChordsRouteByPosition() {
    var router = KeyRouter(keymap: keymap)
    for (k, id) in [(PhysicalKey.a, "select.all"), (.r, "file.reveal"), (.z, "edit.undo")] {
        let r = route(&router, KeyInput(keyCode: k.rawValue, modifiers: [.command], timestamp: 0, character: "ω"))
        #expect(r.actions == [.perform(CommandID(rawValue: id))])
    }
}

@MainActor @Test func modifiersMustMatchForPositionalBindings() {
    var router = KeyRouter(keymap: keymap)
    #expect(route(&router, key(.x, [.option])).consumed == false)
    #expect(route(&router, key(.digit3, [.shift])).actions == [.perform("cull.rate3.advance")])
}

@MainActor @Test func punctuationRoutesByLatinCharacter() throws {
    let layout = try #require(ascii)
    var router = KeyRouter(keymap: keymap)
    let cases: [(PhysicalKey, KeyModifiers, String)] = [
        (.leftBracket, [], "rate.down"), (.rightBracket, [], "rate.up"), (.backslash, [], "cull.clear"),
        (.equal, [], "zoom.in"), (.minus, [], "zoom.out"), (.slash, [.shift], "help.cheatsheet"),
    ]
    for (k, m, id) in cases {
        #expect(route(&router, key(k, m, layout: layout)).actions == [.perform(CommandID(rawValue: id))], "\(k)")
        _ = route(&router, key(k, m, down: false, layout: layout))
    }
}

@MainActor @Test func punctuationFollowsTheCharacterNotThePosition() {
    // A layout where `?` lives on another key: the character decides.
    var router = KeyRouter(keymap: keymap)
    let moved = KeyInput(keyCode: PhysicalKey.m.rawValue, modifiers: [.shift], timestamp: 0, character: "?")
    #expect(route(&router, moved).actions == [.perform("help.cheatsheet")])
    // And a key that types something else at the US position does not fire it.
    let notIt = KeyInput(keyCode: PhysicalKey.slash.rawValue, modifiers: [.shift], timestamp: 1, character: "_")
    #expect(route(&router, notIt).consumed == false)
}

@MainActor @Test func tapToggles() {
    var router = KeyRouter(keymap: keymap)
    #expect(route(&router, key(.z, t: 0)).actions == [.perform("view.zoom")])
    let up = route(&router, key(.z, down: false, t: 0.08))
    #expect(up.consumed && up.actions.isEmpty)
}

@MainActor @Test func holdRevertsOnKeyUp() {
    var router = KeyRouter(keymap: keymap)
    #expect(route(&router, key(.z, t: 0)).actions == [.perform("view.zoom")])
    // Auto-repeat while held does nothing for a toggleOrHold key.
    let rep = route(&router, key(.z, rep: true, t: 0.4))
    #expect(rep.consumed && rep.actions.isEmpty)
    #expect(route(&router, key(.z, down: false, t: 0.5)).actions == [.releaseHold("view.zoom")])
    // The next tap is a fresh press.
    #expect(route(&router, key(.z, t: 1)).actions == [.perform("view.zoom")])
}

@MainActor @Test func holdThresholdIsConfigurable() {
    var router = KeyRouter(keymap: keymap, holdThreshold: 0.1)
    _ = route(&router, key(.z, t: 0))
    #expect(route(&router, key(.z, down: false, t: 0.12)).actions == [.releaseHold("view.zoom")])
}

@MainActor @Test func autoRepeatPolicy() {
    var router = KeyRouter(keymap: keymap)
    // Cull key: only the first press acts (G-12).
    #expect(route(&router, key(.digit3)).actions == [.perform("cull.rate3")])
    for i in 1...5 {
        let r = route(&router, key(.digit3, rep: true, t: Double(i) * 0.03))
        #expect(r.consumed && r.actions.isEmpty)
    }
    // Navigation repeats at the system rate.
    #expect(route(&router, key(.rightArrow)).actions == [.perform("nav.next")])
    #expect(route(&router, key(.rightArrow, rep: true, t: 0.4)).actions == [.perform("nav.next")])
    #expect(route(&router, key(.rightArrow, rep: true, t: 0.43)).actions == [.perform("nav.next")])
}

@MainActor @Test func textFieldKeepsEveryKey() {
    var router = KeyRouter(keymap: keymap)
    for k: PhysicalKey in [.x, .digit3, .z, .rightArrow, .leftBracket] {
        let r = route(&router, key(k), focus: .textInput)
        #expect(!r.consumed && r.actions.isEmpty, "\(k)")
    }
    #expect(!route(&router, key(.a, [.command]), focus: .textInput).consumed)
}

@MainActor @Test func escapeInTextFieldReturnsFocusThenGoesToGrid() {
    var router = KeyRouter(keymap: keymap)
    #expect(route(&router, key(.escape), focus: .textInput).actions == [.returnFocusToCanvas])
    // Its key-up is ours too, and must not leak.
    #expect(route(&router, key(.escape, down: false, t: 0.05), focus: .textInput).consumed)
    // G-13: the next Esc, now on the canvas, is the Grid command.
    #expect(route(&router, key(.escape, t: 1)).actions == [.perform("nav.grid")])
    // Held Esc in the field does not also fall through to Grid on repeat.
    _ = route(&router, key(.escape, down: false, t: 1.1))
    _ = route(&router, key(.escape, t: 2), focus: .textInput)
    let rep = route(&router, key(.escape, rep: true, t: 2.4), focus: .textInput)
    #expect(rep.consumed && rep.actions.isEmpty)
}

@MainActor @Test func modeFiltersBindings() {
    var router = KeyRouter(keymap: keymap)
    #expect(route(&router, key(.escape), mode: .grid).consumed == false)
    #expect(route(&router, key(.escape, t: 1), mode: .compare).actions == [.perform("nav.grid")])
}

@MainActor @Test func unhandledKeyUpPassesThrough() {
    var router = KeyRouter(keymap: keymap)
    #expect(route(&router, key(.q, down: false)).consumed == false)
}

@MainActor @Test func losingFocusRevertsAHeldToggle() {
    var router = KeyRouter(keymap: keymap)
    _ = route(&router, key(.z, t: 0))
    #expect(router.cancelAll(at: 1.0) == [.releaseHold("view.zoom")])
    #expect(router.cancelAll(at: 2.0).isEmpty)
    // A tap interrupted by focus loss stays toggled.
    _ = route(&router, key(.z, t: 3))
    #expect(router.cancelAll(at: 3.05).isEmpty)
}

@MainActor @Test func modifierReleasedBeforeKeyStillEndsTheHold() {
    var router = KeyRouter(keymap: keymap)
    _ = route(&router, key(.z, t: 0))
    #expect(route(&router, key(.z, [.shift], down: false, t: 0.6)).actions == [.releaseHold("view.zoom")])
}

// MARK: layouts

@MainActor @Test func nonLatinLayoutsTypeNonLatinButShareKeyCodes() throws {
    let greek = try #require(KeyLayout.installed(id: "com.apple.keylayout.Greek"))
    let russian = try #require(KeyLayout.installed(id: "com.apple.keylayout.Russian"))
    #expect(greek.typesLatin == false)
    #expect(russian.typesLatin == false)
    #expect(greek.character(keyCode: PhysicalKey.x.rawValue) == "χ")
    #expect(russian.character(keyCode: PhysicalKey.x.rawValue) == "ч")
}

@MainActor @Test func asciiFallbackLabelsNonLatinLayouts() throws {
    let greek = try #require(KeyLayout.installed(id: "com.apple.keylayout.Greek"))
    // Letters fall back to the ASCII-capable layout's label for that key.
    let label = KeyLabels.label(for: .position(.x), layout: greek)
    let isASCII = label.unicodeScalars.allSatisfy { $0.isASCII }
    #expect(isASCII)
    #expect(KeyLabels.label(for: .position(.rightArrow), layout: greek) == "→")
    #expect(KeyLabels.label(for: .character("?"), layout: greek) == "?")
    #expect(KeyLabels.label(for: [.shift, .command]) == "⇧⌘")
}

@MainActor @Test func labelsFollowALatinLayoutThatMovesLetters() throws {
    let dvorak = try #require(KeyLayout.installed(id: "com.apple.keylayout.Dvorak"))
    // The key at QWERTY's X position types `q` on Dvorak: that is what the user must find and press.
    #expect(KeyLabels.label(for: .position(.x), layout: dvorak) == "Q")
}

@MainActor @Test func syntheticGreekEventRoutes() throws {
    // A key-down as the system delivers it with the Greek layout active: keyCode of X, character χ.
    let event = try #require(NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: [], timestamp: 5, windowNumber: 0, context: nil,
        characters: "χ", charactersIgnoringModifiers: "χ", isARepeat: false, keyCode: PhysicalKey.x.rawValue))
    let input = try #require(KeyInput(event: event, layout: ascii))
    var router = KeyRouter(keymap: keymap)
    #expect(route(&router, input).actions == [.perform("cull.reject")])
}
