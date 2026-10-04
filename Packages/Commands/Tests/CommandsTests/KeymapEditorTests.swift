import Foundation
import Testing
@testable import Commands

private func k(_ key: PhysicalKey, _ mods: KeyModifiers = []) -> Shortcut { Shortcut(.position(key), mods) }

private func conflictIDs(_ check: KeyCheck) -> [CommandID] {
    if case .conflicts(let list) = check { list.map(\.command) } else { [] }
}

private func press(_ key: PhysicalKey, _ keymap: Keymap, mods: KeyModifiers = [], mode: ViewMode = .loupe, character: Character? = nil) -> [RoutedAction] {
    var router = KeyRouter(keymap: keymap)
    return router.handle(KeyInput(keyCode: key.rawValue, modifiers: mods, timestamp: 0, character: character), mode: mode, focus: .canvas).actions
}

// MARK: adding, replacing, removing

@Test func aNewKeyIsAddedToTheCommandAndRoutes() {
    var editor = KeymapEditor()
    #expect(editor.assign(k(.q), to: "cull.reject") == .ok)
    #expect(editor.shortcuts(for: "cull.reject") == [k(.x), k(.q)])
    #expect(editor.isCustomized("cull.reject"))
    #expect(press(.q, editor.resolved.keymap) == [.perform("cull.reject")])
    #expect(press(.q, editor.resolved.keymap, mods: [.shift]) == [.performAdvancing("cull.reject")])
    #expect(press(.x, editor.resolved.keymap) == [.perform("cull.reject")])
}

@Test func replacingAKeyTakesThePlaceOfTheOldOne() {
    var editor = KeymapEditor()
    #expect(editor.assign(k(.q), to: "cull.reject", replacing: k(.x)) == .ok)
    #expect(editor.shortcuts(for: "cull.reject") == [k(.q)])
    #expect(press(.x, editor.resolved.keymap).isEmpty)
    #expect(press(.x, editor.resolved.keymap, mods: [.shift]).isEmpty)
}

@Test func removingTheLastKeyUnbindsTheCommandAndItsTwin() throws {
    var editor = KeymapEditor()
    editor.remove(k(.x), from: "cull.reject")
    #expect(editor.shortcuts(for: "cull.reject").isEmpty)
    #expect(editor.file.bindings["cull.reject"] == [])
    #expect(press(.x, editor.resolved.keymap).isEmpty)
    #expect(press(.x, editor.resolved.keymap, mods: [.shift]).isEmpty)
}

@Test func theFileHoldsOnlyWhatDiffersFromTheLayerBelow() {
    var editor = KeymapEditor()
    editor.assign(k(.q), to: "cull.reject")
    #expect(editor.customizedCount == 1)
    // Taking the new key away again gives back the default list, so the entry goes.
    editor.remove(k(.q), from: "cull.reject")
    #expect(editor.customizedCount == 0)
    #expect(!editor.isCustomized("cull.reject"))
    #expect(editor.file.bindings.isEmpty)
}

@Test func resetGivesBackOneCommandAndResetAllGivesBackEverything() {
    var editor = KeymapEditor()
    editor.assign(k(.q), to: "cull.reject")
    editor.assign(k(.d), to: "nav.next")
    editor.reset("cull.reject")
    #expect(editor.shortcuts(for: "cull.reject") == [k(.x)])
    #expect(editor.shortcuts(for: "nav.next") == [k(.rightArrow), k(.d)])
    editor.resetAll()
    #expect(editor.file.bindings.isEmpty)
    #expect(editor.shortcuts(for: "nav.next") == [k(.rightArrow)])
}

@Test func entriesTheEditorDoesNotKnowSurviveAnEdit() {
    let file = KeymapFile(bindings: ["from.the.future": [KeymapFile.Entry(Shortcut(.position(.z)))]])
    var editor = KeymapEditor(file: file)
    editor.assign(k(.q), to: "cull.reject")
    #expect(editor.file.bindings["from.the.future"] != nil)
    #expect(editor.resolved.problems.count == 1)
}

@Test func theKeysInForceFollowTheFileTheEditorLoads() throws {
    var editor = KeymapEditor()
    let file = try KeymapFile.decode(Data(#"{"version":1,"bindings":{"nav.last":[{"position":"l"}]}}"#.utf8))
    editor.load(file)
    #expect(editor.shortcuts(for: "nav.last") == [k(.l)])
    #expect(editor.isCustomized("nav.last"))
}

// MARK: checking

@Test func aKeyOfAnotherCommandInTheSameModesIsAConflict() {
    let editor = KeymapEditor()
    let result = editor.check(k(.e), for: "cull.reject")
    #expect(result == .conflicts([
        KeyConflict(command: "view.loupe", title: "Open in Loupe", modes: [.grid, .compare], shortcut: k(.e), isShiftTwin: false),
    ]))
}

@Test func aConflictChangesNothingUntilTheUserReassigns() {
    var editor = KeymapEditor()
    let before = editor.file
    #expect(conflictIDs(editor.assign(k(.e), to: "cull.reject")) == ["view.loupe"])
    #expect(editor.file == before)
    #expect(editor.assign(k(.e), to: "cull.reject", reassign: true) == .ok)
    #expect(editor.shortcuts(for: "cull.reject") == [k(.x), k(.e)])
    #expect(editor.shortcuts(for: "view.loupe") == [k(.return), k(.space)])
    // Reject works in every mode, so `E` no longer opens Loupe from Grid.
    #expect(press(.e, editor.resolved.keymap, mode: .grid) == [.perform("cull.reject")])
    #expect(press(.e, editor.resolved.keymap, mode: .loupe) == [.perform("cull.reject")])
}

@Test func theSameKeyInModesThatDoNotOverlapIsNotAConflict() {
    // `↓` is Next Row in Grid, Next EXIF Value in Loupe and Swap in Compare.
    var editor = KeymapEditor()
    editor.remove(k(.downArrow), from: "compare.swap")
    #expect(editor.check(k(.downArrow), for: "compare.swap") == .ok)
    #expect(editor.check(k(.downArrow), for: "grid.smaller") != .ok)
}

@Test func aCommandForEveryModeConflictsWithAKeyInOneMode() {
    // `Home` goes to the first photo in every mode, so a Grid-only command cannot have it.
    let editor = KeymapEditor()
    #expect(conflictIDs(editor.check(k(.home), for: "grid.larger")) == ["nav.first"])
}

@Test func theConflictListsTheModesBothCommandsAnswerIn() {
    let editor = KeymapEditor()
    guard case .conflicts(let list) = editor.check(k(.upArrow), for: "zoom.sticky") else { Issue.record("no conflict"); return }
    // Sticky zoom works in Loupe; `↑` is Next EXIF Value there, and Up a Row in Grid (no overlap).
    #expect(list.map(\.command) == ["info.fieldPrevious"])
    #expect(list.first?.modes == [.loupe])
}

@Test func aCharacterKeyAndAPositionKeyOnOnePressAreOneKey() {
    let editor = KeymapEditor()
    // `/` is `.position(.slash)` for Deselect Active Photo; the recorder gives `.character("/")` for the same press.
    #expect(conflictIDs(editor.check(Shortcut(.character("/")), for: "info.cycle")) == ["select.deselectActive"])
    // `?` is `.character("?")` for the cheat sheet; `⇧/` as a position is the same press.
    #expect(conflictIDs(editor.check(k(.slash, [.shift]), for: "info.cycle")) == ["help.cheatsheet"])
    #expect(conflictIDs(editor.check(Shortcut(.character("\\")), for: "info.cycle")) == ["filter.bar"])
}

@Test func theCommandsOwnKeyIsADuplicateEvenInAnotherForm() {
    let editor = KeymapEditor()
    #expect(editor.check(k(.x), for: "cull.reject") == .duplicate)
    #expect(editor.check(k(.leftBracket), for: "cull.rate.down") == .duplicate)
    #expect(editor.check(Shortcut(.character("[")), for: "cull.rate.down") == .duplicate)
}

@Test func aKeyThatIsTheTwinOfAnotherCommandsKeyCannotBeReassigned() {
    var editor = KeymapEditor()
    let before = editor.file
    guard case .conflicts(let list) = editor.check(k(.x, [.shift]), for: "info.cycle") else { Issue.record("no conflict"); return }
    #expect(list.map(\.command) == ["cull.reject"])
    #expect(list.first?.isShiftTwin == true)
    #expect(editor.assign(k(.x, [.shift]), to: "info.cycle", reassign: true) != .ok)
    #expect(editor.file == before)
}

@Test func theTwinOfANewKeyCountsToo() {
    // Give `⇧Q` to Cycle Info. A key for Reject on `Q` would make `⇧Q` its twin, which Cycle Info holds.
    var editor = KeymapEditor()
    editor.assign(k(.q, [.shift]), to: "info.cycle")
    #expect(conflictIDs(editor.check(k(.q), for: "cull.reject")) == ["info.cycle"])
    // `⇧Q` is a real key of Cycle Info, so the user may reassign it. Cycle Info is back to its default list.
    #expect(editor.assign(k(.q), to: "cull.reject", reassign: true) == .ok)
    #expect(!editor.isCustomized("info.cycle"))
    #expect(press(.q, editor.resolved.keymap, mods: [.shift]) == [.performAdvancing("cull.reject")])
}

@Test func reservedKeysAreRefusedWithTheirReason() {
    var editor = KeymapEditor()
    let before = editor.file
    guard case .reserved(let reason) = editor.assign(k(.q, [.command]), to: "cull.reject") else { Issue.record("not reserved"); return }
    #expect(!reason.isEmpty)
    #expect(editor.file == before)
    // Space is the pan key in Loupe. A Grid-only command is not refused for it; it clashes with Open in Loupe instead.
    if case .reserved = editor.check(k(.space), for: "zoom.toggle") {} else { Issue.record("Space in Loupe") }
    #expect(conflictIDs(editor.check(k(.space), for: "nav.up")) == ["view.loupe"])
}

@Test func unknownCommandsAreLeftAlone() {
    var editor = KeymapEditor()
    #expect(editor.assign(k(.q), to: "no.such.command") == .ok)
    #expect(editor.file.bindings["no.such.command"] != nil)
}

// MARK: the pieces together

@Test func everyDefaultKeyIsFreeOfClashesWhenFormsAreComparedAsPresses() {
    let table = CommandTable.standard
    let bindings = table.defaultBindings
    for (i, a) in bindings.enumerated() {
        for b in bindings[(i + 1)...] where a.command != b.command {
            let same = USLayout.press(of: Shortcut(a.key, a.modifiers)) == USLayout.press(of: Shortcut(b.key, b.modifiers))
            #expect(!(same && Keymap.overlap(a.modes, b.modes)), "\(a.command.rawValue) and \(b.command.rawValue) share a press")
        }
    }
}

@Test func aRemapShowsInTheCheatSheetAndInTheKeymapLookup() {
    var editor = KeymapEditor()
    editor.assign(k(.q), to: "cull.reject", replacing: k(.x))
    let sections = CheatSheet.sections(table: .standard, keymap: editor.resolved.keymap, mode: .loupe)
    let entry = sections.flatMap(\.entries).first { $0.id == "cull.reject" }
    #expect(entry?.shortcuts == [k(.q)])
    let input = KeyInput(keyCode: PhysicalKey.q.rawValue, timestamp: 0)
    #expect(editor.resolved.keymap.command(for: input, mode: .loupe) == "cull.reject")
    #expect(Keymap.resolve(table: .standard, userFile: nil).keymap.command(for: input, mode: .loupe) == nil)
}

@Test func aFileFromTheEditorSurvivesARelaunch() throws {
    var editor = KeymapEditor()
    editor.assign(Shortcut(.character("=")), to: "overlay.peakingMode")
    editor.assign(k(.f5), to: "info.cycle", replacing: k(.i))
    editor.remove(k(.end), from: "nav.last")
    let relaunched = KeymapEditor(file: try KeymapFile.decode(editor.file.encoded()))
    for id in ["overlay.peakingMode", "info.cycle", "nav.last", "cull.reject"] as [CommandID] {
        #expect(relaunched.shortcuts(for: id) == editor.shortcuts(for: id))
    }
}
