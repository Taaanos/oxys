import AppKit
import Testing
@testable import Commands

/// M-24: the cull loop on non-Latin layouts. Key-downs are built the way the system delivers them under
/// that layout (key code of the key, characters of the layout) and routed through the standard keymap.
@MainActor private let ascii = KeyLayout.installed(id: "com.apple.keylayout.ABC") ?? KeyLayout.installed(id: "com.apple.keylayout.US")
private let layoutIDs = ["com.apple.keylayout.Greek", "com.apple.keylayout.Russian"]
private let standard = Keymap.resolve(table: .standard, userFile: nil).keymap

@MainActor private func event(_ key: PhysicalKey, _ mods: KeyModifiers, layout: KeyLayout, down: Bool = true, t: Double) throws -> KeyInput {
    var flags: NSEvent.ModifierFlags = []
    if mods.contains(.shift) { flags.insert(.shift) }
    if mods.contains(.control) { flags.insert(.control) }
    if mods.contains(.option) { flags.insert(.option) }
    if mods.contains(.command) { flags.insert(.command) }
    let typed = layout.character(keyCode: key.rawValue, shift: mods.contains(.shift)).map(String.init) ?? ""
    let nsEvent = try #require(NSEvent.keyEvent(
        with: down ? .keyDown : .keyUp, location: .zero, modifierFlags: flags, timestamp: t, windowNumber: 0, context: nil,
        characters: typed, charactersIgnoringModifiers: typed, isARepeat: false, keyCode: key.rawValue))
    // The command center passes the ASCII-capable layout, as `route(_:)` does.
    return try #require(KeyInput(event: nsEvent, layout: ascii))
}

@MainActor private func actions(_ spec: Shortcut, key: PhysicalKey, layout: KeyLayout, mode: ViewMode) throws -> [RoutedAction] {
    var router = KeyRouter(keymap: standard)
    var result = try router.handle(event(key, spec.modifiers, layout: layout, t: 0), mode: mode, focus: .canvas).actions
    result += try router.handle(event(key, spec.modifiers, layout: layout, down: false, t: 0.01), mode: mode, focus: .canvas).actions
    return result
}

@MainActor @Test(arguments: layoutIDs)
func everyPositionalDefaultKeyRoutesTheSameOnANonLatinLayout(id: String) throws {
    let layout = try #require(KeyLayout.installed(id: id))
    let latin = try #require(ascii)
    #expect(layout.typesLatin == false)
    var checked = 0
    for binding in standard.bindings {
        guard case .position(let key) = binding.key else { continue }
        for mode in ViewMode.allCases {
            let spec = Shortcut(binding.key, binding.modifiers)
            let expected = try actions(spec, key: key, layout: latin, mode: mode)
            let actual = try actions(spec, key: key, layout: layout, mode: mode)
            #expect(actual == expected, "\(binding.command.rawValue) in \(mode) on \(id)")
            checked += expected.isEmpty ? 0 : 1
        }
    }
    #expect(checked > 50)
}

@MainActor @Test(arguments: layoutIDs)
func aFullCullLoopRunsOnANonLatinLayout(id: String) throws {
    let layout = try #require(KeyLayout.installed(id: id))
    var router = KeyRouter(keymap: standard)
    var t = 0.0
    func press(_ key: PhysicalKey, _ mods: KeyModifiers = [], mode: ViewMode = .loupe) throws -> [RoutedAction] {
        t += 1
        let down = try router.handle(event(key, mods, layout: layout, t: t), mode: mode, focus: .canvas).actions
        t += 0.05
        return try down + router.handle(event(key, mods, layout: layout, down: false, t: t), mode: mode, focus: .canvas).actions
    }
    // First pass: next, rate 3 and advance, reject, label red, back, previous, then the cheat sheet and Grid.
    #expect(try press(.rightArrow) == [.perform("nav.next")])
    #expect(try press(.digit3, [.shift]) == [.performAdvancing("cull.rate.3")])
    #expect(try press(.x) == [.perform("cull.reject")])
    #expect(try press(.digit6) == [.perform("cull.label.red")])
    #expect(try press(.leftArrow) == [.perform("nav.previous")])
    #expect(try press(.digit5) == [.perform("cull.rate.5")])
    #expect(try press(.x, [.shift]) == [.performAdvancing("cull.reject")])
    #expect(try press(.r, [.command]) == [.perform("file.reveal")])
    #expect(try press(.a, [.command], mode: .grid) == [.perform("select.all")])
}
