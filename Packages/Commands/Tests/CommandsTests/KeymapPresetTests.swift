import Foundation
import Testing
@testable import Commands

private func k(_ key: PhysicalKey, _ mods: KeyModifiers = []) -> Shortcut { Shortcut(.position(key), mods) }

private func resolved(_ presetID: String?) -> Keymap {
    Keymap.resolve(table: .standard, file: KeymapFile(preset: presetID)).keymap
}

private func press(_ key: PhysicalKey, _ keymap: Keymap, mods: KeyModifiers = [], mode: ViewMode = .loupe, character: Character? = nil) -> [RoutedAction] {
    var router = KeyRouter(keymap: keymap)
    return router.handle(KeyInput(keyCode: key.rawValue, modifiers: mods, timestamp: 0, character: character), mode: mode, focus: .canvas).actions
}

@Test func photoMechanicShipsWithTheApp() throws {
    let preset = try #require(KeymapPreset.bundled.first { $0.id == "photomechanic" })
    #expect(preset.name == "Photo Mechanic")
    #expect(preset.file.version == KeymapFile.currentVersion)
}

@Test func everyBundledPresetUsesOnlyKnownCommandsAndKeys() {
    for preset in KeymapPreset.bundled {
        for (name, entries) in preset.file.bindings {
            #expect(CommandTable.standard[CommandID(rawValue: name)] != nil, "\(preset.id): unknown command \(name)")
            for entry in entries { #expect((try? entry.shortcut().get()) != nil, "\(preset.id): \(name): bad entry") }
        }
    }
}

@Test func noBundledPresetPutsTwoCommandsOnOnePress() {
    // The same rule as the Default keys: one press, one command in each mode, with `.character` and `.position` of one key as one press.
    for preset in KeymapPreset.bundled {
        let bindings = resolved(preset.id).bindings
        for (i, a) in bindings.enumerated() {
            for b in bindings[(i + 1)...] where a.command != b.command {
                let same = USLayout.press(of: Shortcut(a.key, a.modifiers)) == USLayout.press(of: Shortcut(b.key, b.modifiers))
                #expect(!(same && Keymap.overlap(a.modes, b.modes)), "\(preset.id): \(a.command.rawValue) and \(b.command.rawValue)")
            }
        }
    }
}

@Test func noBundledPresetTakesAReservedKey() {
    for preset in KeymapPreset.bundled {
        for b in resolved(preset.id).bindings {
            #expect(ReservedShortcuts.reason(for: Shortcut(b.key, b.modifiers), modes: b.modes) == nil, "\(preset.id): \(b.command.rawValue)")
        }
    }
}

@Test func aPresetLeavesTheCommandsItDoesNotListOnTheirDefaultKeys() throws {
    let preset = try #require(KeymapPreset.bundled.first { $0.id == "photomechanic" })
    let defaults = resolved(nil)
    let withPreset = resolved(preset.id)
    for command in CommandTable.standard.commands where preset.file.bindings[command.id.rawValue] == nil {
        #expect(withPreset.shortcuts(for: command.id) == defaults.shortcuts(for: command.id), "\(command.id.rawValue)")
    }
}

@Test func photoMechanicStarsGoOnControlDigitsAndTheDefaultKeysStay() {
    let keymap = resolved("photomechanic")
    #expect(keymap.shortcuts(for: "cull.rate.3") == [k(.digit3, [.control]), k(.digit3), k(.keypad3)])
    #expect(press(.digit3, keymap, mods: [.control]) == [.perform("cull.rate.3")])
    #expect(press(.digit3, keymap) == [.perform("cull.rate.3")])
    // The twin follows the first key too.
    #expect(press(.digit3, keymap, mods: [.control, .shift]) == [.performAdvancing("cull.rate.3")])
    #expect(press(.digit3, keymap, mods: [.shift]) == [.performAdvancing("cull.rate.3")])
}

@Test func photoMechanicZoomsInOnPlusAndOverlaysOnBAndN() {
    let keymap = resolved("photomechanic")
    #expect(keymap.shortcuts(for: "zoom.in").first == Shortcut(.character("+")))
    #expect(press(.equal, keymap, mods: [.shift], character: "+") == [.perform("zoom.in")])
    #expect(press(.equal, keymap, character: "=") == [.perform("zoom.in")])
    #expect(press(.b, keymap) == [.perform("overlay.highlights")])
    #expect(press(.n, keymap) == [.perform("overlay.shadows")])
    #expect(press(.h, keymap) == [.perform("overlay.highlights")])
    #expect(press(.v, keymap, mode: .grid) == [.perform("compare.enter")])
}

@Test func theFirstKeyOfAPresetCommandIsThePresetsKey() {
    // The menu shows the first key.
    let keymap = resolved("photomechanic")
    #expect(keymap.shortcuts(for: "file.reload").first == k(.f5))
    #expect(keymap.shortcuts(for: "select.none").first == k(.d, [.command]))
}

// MARK: choosing a preset in the editor

@Test func choosingAPresetRemovesTheUsersChangesAndKeepsThePreset() {
    var editor = KeymapEditor()
    editor.assign(k(.q), to: "cull.reject")
    #expect(editor.customizedCount == 1)
    let chosen = editor.selectPreset("photomechanic")
    #expect(chosen)
    #expect(editor.presetID == "photomechanic")
    #expect(editor.customizedCount == 0)
    #expect(editor.shortcuts(for: "cull.rate.1").first == k(.digit1, [.control]))
    #expect(editor.shortcuts(for: "cull.reject") == [k(.x)])
    // The file now says which preset, and nothing else.
    #expect(editor.file == KeymapFile(preset: "photomechanic"))
}

@Test func anUnknownPresetIsRefusedAndChangesNothing() {
    var editor = KeymapEditor()
    editor.assign(k(.q), to: "cull.reject")
    let before = editor.file
    let chosen = editor.selectPreset("nope")
    #expect(!chosen)
    #expect(editor.file == before)
}

@Test func theDefaultKeysComeBackWithNil() {
    var editor = KeymapEditor()
    editor.selectPreset("photomechanic")
    editor.selectPreset(nil)
    #expect(editor.presetID == nil)
    #expect(editor.file == KeymapFile())
    #expect(editor.shortcuts(for: "cull.rate.1") == [k(.digit1), k(.keypad1)])
}

@Test func yourChangesSitOnTopOfThePresetAndResetGoesBackToIt() {
    var editor = KeymapEditor()
    editor.selectPreset("photomechanic")
    editor.assign(k(.q), to: "cull.rate.1")
    #expect(editor.shortcuts(for: "cull.rate.1") == [k(.digit1, [.control]), k(.digit1), k(.keypad1), k(.q)])
    #expect(editor.isCustomized("cull.rate.1"))
    // Removing the new key gives the preset's list again, so the entry goes.
    editor.remove(k(.q), from: "cull.rate.1")
    #expect(!editor.isCustomized("cull.rate.1"))
    editor.assign(k(.q), to: "cull.rate.1")
    editor.reset("cull.rate.1")
    #expect(editor.shortcuts(for: "cull.rate.1").first == k(.digit1, [.control]))
    editor.assign(k(.q), to: "cull.rate.1")
    editor.resetAll()
    #expect(editor.presetID == "photomechanic")
    #expect(editor.customizedCount == 0)
}

@Test func aKeyThePresetTookIsAConflictLikeAnyOther() {
    var editor = KeymapEditor()
    editor.selectPreset("photomechanic")
    // `⌃3` is now Rate 3 Stars. Another command cannot have it without a reassign.
    if case .conflicts(let list) = editor.check(k(.digit3, [.control]), for: "info.cycle") {
        #expect(list.map(\.command) == ["cull.rate.3"])
    } else {
        Issue.record("no conflict")
    }
}

@Test func theFileOfAPresetUserSurvivesARelaunch() throws {
    var editor = KeymapEditor()
    editor.selectPreset("photomechanic")
    editor.assign(k(.q), to: "cull.reject")
    let relaunched = KeymapEditor(file: try KeymapFile.decode(editor.file.encoded()))
    #expect(relaunched.presetID == "photomechanic")
    #expect(relaunched.shortcuts(for: "cull.reject") == [k(.x), k(.q)])
    #expect(relaunched.shortcuts(for: "cull.rate.2").first == k(.digit2, [.control]))
}
