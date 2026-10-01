import Foundation
import Testing
@testable import Commands

private func resolve(_ json: String?, table: CommandTable = .standard) -> ResolvedKeymap {
    Keymap.resolve(table: table, userFile: json.map { Data($0.utf8) })
}

private func keys(_ r: ResolvedKeymap, _ id: CommandID) -> [Shortcut] { r.keymap.shortcuts(for: id) }

@Test func standardTableHasUniqueIDsAndNoDefaultKeyConflicts() {
    let table = CommandTable.standard
    #expect(Set(table.commands.map(\.id)).count == table.commands.count)
    let bindings = table.defaultBindings
    for (i, a) in bindings.enumerated() {
        for b in bindings[(i + 1)...] where a.key == b.key && a.modifiers == b.modifiers {
            #expect(!(a.modes.isEmpty || b.modes.isEmpty || !a.modes.isDisjoint(with: b.modes)),
                    "\(a.command.rawValue) and \(b.command.rawValue) share a key")
        }
    }
}

@Test func addingACommandGivesAMenuItemAndAKey() {
    let table = CommandTable(CommandTable.standard.commands + [
        Command("test.extra", "Reject", menu: .init(.photo, group: 9), modes: [.loupe], keys: [Shortcut(.position(.q))]),
    ])
    #expect(table.groups(in: .photo).last?.map(\.id) == ["test.extra"])
    let r = resolve(nil, table: table)
    #expect(keys(r, "test.extra") == [Shortcut(.position(.q))])
    var router = KeyRouter(keymap: r.keymap)
    let result = router.handle(KeyInput(keyCode: PhysicalKey.q.rawValue, timestamp: 0), mode: .loupe, focus: .canvas)
    #expect(result.actions == [.perform("test.extra")])
    // Its modes carry over to the key.
    let grid = router.handle(KeyInput(keyCode: PhysicalKey.q.rawValue, timestamp: 1), mode: .grid, focus: .canvas)
    #expect(!grid.consumed)
}

@Test func menuGroupsKeepTableOrderAndSeparateGroups() {
    let table = CommandTable([
        Command("a", "A", menu: .init(.view, group: 1)),
        Command("b", "B", menu: .init(.view, group: 0)),
        Command("c", "C", menu: .init(.view, group: 1)),
        Command("d", "D", menu: .init(.file)),
    ])
    #expect(table.groups(in: .view).map { $0.map(\.id.rawValue) } == [["b"], ["a", "c"]])
    #expect(table.groups(in: .filter).isEmpty)
}

@Test func standardMenuOrder() {
    #expect(AppMenu.allCases.map { "\($0)" } == ["app", "file", "edit", "view", "photo", "filter", "window", "help"])
}

@Test func enablement() {
    let nav = CommandTable.standard["nav.next"]!
    #expect(!nav.isEnabled(in: .init(mode: .loupe, hasPhotos: false)))
    #expect(nav.isEnabled(in: .init(mode: .loupe, hasPhotos: true)))
    #expect(CommandTable.standard["file.open"]!.isEnabled(in: .init(mode: .loupe, hasPhotos: false)))
    let loupeOnly = Command("x", "X", menu: nil, modes: [.loupe])
    #expect(!loupeOnly.isEnabled(in: .init(mode: .grid, hasPhotos: true)))
}

@Test func navigationKeysRepeatAndOthersDoNot() {
    let r = resolve(nil)
    var router = KeyRouter(keymap: r.keymap)
    let right = PhysicalKey.rightArrow.rawValue
    _ = router.handle(KeyInput(keyCode: right, timestamp: 0), mode: .loupe, focus: .canvas)
    let again = router.handle(KeyInput(keyCode: right, isRepeat: true, timestamp: 0.5), mode: .loupe, focus: .canvas)
    #expect(again.actions == [.perform("nav.next")])
    let home = PhysicalKey.home.rawValue
    _ = router.handle(KeyInput(keyCode: home, timestamp: 1), mode: .loupe, focus: .canvas)
    #expect(router.handle(KeyInput(keyCode: home, isRepeat: true, timestamp: 1.5), mode: .loupe, focus: .canvas).actions.isEmpty)
}

@Test func noUserFileMeansDefaults() {
    let r = resolve(nil)
    #expect(r.problems.isEmpty)
    #expect(keys(r, "nav.next") == [Shortcut(.position(.rightArrow))])
    #expect(keys(r, "file.open") == [Shortcut(.position(.o), [.command])])
}

@Test func userFileReplacesACommandsKeys() {
    let r = resolve(#"{"version":1,"bindings":{"nav.next":[{"position":"d"},{"position":"rightArrow","modifiers":["shift"]}]}}"#)
    #expect(r.problems.isEmpty)
    #expect(keys(r, "nav.next") == [Shortcut(.position(.d)), Shortcut(.position(.rightArrow), [.shift])])
    // Replacing keeps the command's own behavior.
    #expect(r.keymap.bindings.filter { $0.command == "nav.next" }.allSatisfy { $0.behavior == .repeating })
    #expect(keys(r, "nav.previous") == [Shortcut(.position(.leftArrow))])
}

@Test func emptyListUnbinds() {
    let r = resolve(#"{"version":1,"bindings":{"nav.last":[]}}"#)
    #expect(keys(r, "nav.last").isEmpty)
}

@Test func aClaimedKeyIsTakenFromTheDefaultOwner() {
    let r = resolve(#"{"version":1,"bindings":{"nav.last":[{"position":"leftArrow"}]}}"#)
    #expect(keys(r, "nav.last") == [Shortcut(.position(.leftArrow))])
    #expect(keys(r, "nav.previous").isEmpty)
}

@Test func characterBindingsParse() {
    let r = resolve(#"{"version":1,"bindings":{"nav.first":[{"character":"[","modifiers":["command"]}]}}"#)
    #expect(keys(r, "nav.first") == [Shortcut(.character("["), [.command])])
}

@Test func badEntriesAreSkippedAndReportedWhileTheRestApplies() {
    let r = resolve(#"""
    {"version":1,"bindings":{
      "nope":[{"position":"x"}],
      "nav.next":[{"position":"notAKey"}],
      "nav.previous":[{"position":"a","character":"b"}],
      "nav.first":[{"character":"ab"}],
      "nav.last":[{"character":"[","modifiers":["shift"]}],
      "file.open":[{"position":"p","modifiers":["hyper"]}]}}
    """#)
    #expect(r.problems.count == 6)
    // Commands named in the file lose their defaults even when every entry was bad: the file said so.
    #expect(keys(r, "nav.next").isEmpty)
}

@Test func twoUserBindingsOnOneKeyKeepTheFirstByName() {
    let r = resolve(#"{"version":1,"bindings":{"nav.first":[{"position":"g"}],"nav.last":[{"position":"g"}]}}"#)
    #expect(keys(r, "nav.first") == [Shortcut(.position(.g))])
    #expect(keys(r, "nav.last").isEmpty)
    #expect(r.problems.count == 1)
}

@Test func unreadableOrNewerFilesLeaveDefaults() {
    for json in ["not json", #"{"version":2,"bindings":{"nav.next":[]}}"#] {
        let r = resolve(json)
        #expect(r.problems.count == 1)
        #expect(keys(r, "nav.next") == [Shortcut(.position(.rightArrow))])
    }
}

@Test func physicalKeyNamesRoundTrip() {
    for key in PhysicalKey.allCases { #expect(PhysicalKey(name: key.name) == key) }
}

@Test func cullKeysHaveShiftTwinsThatAdvance() {
    var router = KeyRouter(keymap: resolve(nil).keymap)
    func press(_ key: PhysicalKey, _ mods: KeyModifiers = [], at t: Double, character: Character? = nil) -> [RoutedAction] {
        let down = router.handle(KeyInput(keyCode: key.rawValue, modifiers: mods, timestamp: t, character: character), mode: .loupe, focus: .canvas).actions
        _ = router.handle(KeyInput(keyCode: key.rawValue, modifiers: mods, isDown: false, timestamp: t + 0.05), mode: .loupe, focus: .canvas)
        return down
    }
    #expect(press(.digit3, at: 0) == [.perform("cull.rate.3")])
    #expect(press(.digit3, [.shift], at: 1) == [.performAdvancing("cull.rate.3")])
    #expect(press(.keypad3, [.shift], at: 2) == [.performAdvancing("cull.rate.3")])
    #expect(press(.x, [.shift], at: 3) == [.performAdvancing("cull.reject")])
    #expect(press(.leftBracket, at: 4, character: "[") == [.perform("cull.rate.down")])
    #expect(press(.rightBracket, [.shift], at: 5, character: "}") == [.performAdvancing("cull.rate.up")])
    // Purple is menu-only.
    #expect(!resolve(nil).keymap.bindings.contains { $0.command == "cull.label.purple" })
}

@Test func cullKeysIgnoreAutoRepeat() {
    var router = KeyRouter(keymap: resolve(nil).keymap)
    let key = PhysicalKey.digit4.rawValue
    #expect(router.handle(KeyInput(keyCode: key, timestamp: 0), mode: .loupe, focus: .canvas).actions == [.perform("cull.rate.4")])
    let repeated = router.handle(KeyInput(keyCode: key, isRepeat: true, timestamp: 0.5), mode: .loupe, focus: .canvas)
    #expect(repeated.consumed && repeated.actions.isEmpty)
    // Grid joins the cull modes in M-12.
    #expect(router.handle(KeyInput(keyCode: PhysicalKey.digit5.rawValue, timestamp: 1), mode: .grid, focus: .canvas).actions == [.perform("cull.rate.5")])
}

@Test func gridKeysBelongToGridAndGComesBack() {
    var router = KeyRouter(keymap: resolve(nil).keymap)
    func press(_ key: PhysicalKey, _ mode: ViewMode, at t: Double, character: Character? = nil) -> [RoutedAction] {
        router.handle(KeyInput(keyCode: key.rawValue, timestamp: t, character: character), mode: mode, focus: .canvas).actions
    }
    #expect(press(.downArrow, .grid, at: 0) == [.perform("nav.down")])
    #expect(press(.downArrow, .loupe, at: 1) == [.perform("info.fieldNext")])   // M-16: Loupe's ↓ walks the EXIF values
    #expect(press(.return, .grid, at: 2) == [.perform("view.loupe")])
    #expect(press(.space, .grid, at: 3) == [.perform("view.loupe")])
    #expect(press(.return, .loupe, at: 4).isEmpty)
    #expect(press(.space, .loupe, at: 4.5).isEmpty)  // M-13/Q2: tapping Space in Loupe does nothing
    #expect(press(.g, .loupe, at: 5) == [.perform("view.grid")])
    #expect(press(.g, .grid, at: 6).isEmpty)
    #expect(press(.minus, .grid, at: 7, character: "-") == [.perform("grid.smaller")])
    #expect(press(.equal, .grid, at: 8, character: "=") == [.perform("grid.larger")])
    #expect(press(.minus, .loupe, at: 9, character: "-") == [.perform("zoom.out")])  // M-15 gives it Loupe's meaning
}

@Test func menuShowsTheBareKeyNotTheShiftTwin() {
    let keys = resolve(nil).keymap.shortcuts(for: "cull.rate.3")
    #expect(keys.first == Shortcut(.position(.digit3)))
    #expect(keys.count == 2)
}

/// Every transition of the PRD's mode diagram that exists before Compare (V-08), by key.
@Test func modeDiagramTransitionsWorkByKey() {
    var router = KeyRouter(keymap: resolve(nil).keymap)
    var t = 0.0
    func press(_ key: PhysicalKey, _ mode: ViewMode) -> [RoutedAction] {
        t += 1
        return router.handle(KeyInput(keyCode: key.rawValue, timestamp: t), mode: mode, focus: .canvas).actions
    }
    #expect(press(.e, .grid) == [.perform("view.loupe")])
    #expect(press(.return, .grid) == [.perform("view.loupe")])
    #expect(press(.g, .loupe) == [.perform("view.grid")])
    #expect(press(.escape, .loupe) == [.perform("view.grid")])
    // Compare's two exits exist already; the enter keys arrive with V-08.
    #expect(press(.e, .compare) == [.perform("view.loupe")])
    #expect(press(.g, .compare) == [.perform("view.grid")])
    #expect(press(.escape, .compare) == [.perform("view.grid")])
    // Esc and E do nothing in Grid, G does nothing in Grid.
    #expect(press(.escape, .grid).isEmpty)
    #expect(press(.g, .grid).isEmpty)
    // E does nothing in Loupe.
    #expect(press(.e, .loupe).isEmpty)
}

@Test func tabTogglesChromeInEveryModeEvenWithoutPhotos() {
    var router = KeyRouter(keymap: resolve(nil).keymap)
    for (i, mode) in ViewMode.allCases.enumerated() {
        let r = router.handle(KeyInput(keyCode: PhysicalKey.tab.rawValue, timestamp: Double(i)), mode: mode, focus: .canvas)
        #expect(r.actions == [.perform("view.chrome")])
    }
    #expect(CommandTable.standard["view.chrome"]!.isEnabled(in: .init(mode: .grid, hasPhotos: false)))
}

@Test func zKeyTogglesAndHoldReleases() {
    var router = KeyRouter(keymap: resolve(nil).keymap)
    let z = PhysicalKey.z.rawValue
    // Tap: down toggles, a quick up does nothing more.
    #expect(router.handle(KeyInput(keyCode: z, timestamp: 0), mode: .loupe, focus: .canvas).actions == [.perform("zoom.toggle")])
    #expect(router.handle(KeyInput(keyCode: z, isDown: false, timestamp: 0.05), mode: .loupe, focus: .canvas).actions.isEmpty)
    // Hold: down toggles, up after the threshold toggles back.
    #expect(router.handle(KeyInput(keyCode: z, timestamp: 1), mode: .loupe, focus: .canvas).actions == [.perform("zoom.toggle")])
    #expect(router.handle(KeyInput(keyCode: z, isDown: false, timestamp: 2), mode: .loupe, focus: .canvas).actions == [.releaseHold("zoom.toggle")])
    // Not in Grid.
    #expect(router.handle(KeyInput(keyCode: z, timestamp: 3), mode: .grid, focus: .canvas).actions.isEmpty)
}

@Test func commandDigitsZoomWhilePlainDigitsRate() {
    var router = KeyRouter(keymap: resolve(nil).keymap)
    let one = PhysicalKey.digit1.rawValue, zero = PhysicalKey.digit0.rawValue
    #expect(router.handle(KeyInput(keyCode: one, modifiers: [.command], timestamp: 0), mode: .loupe, focus: .canvas).actions == [.perform("zoom.actual")])
    #expect(router.handle(KeyInput(keyCode: zero, modifiers: [.command], timestamp: 1), mode: .loupe, focus: .canvas).actions == [.perform("zoom.fit")])
    #expect(router.handle(KeyInput(keyCode: one, timestamp: 2), mode: .loupe, focus: .canvas).actions == [.perform("cull.rate.1")])
}

@Test func zoomStepsPanAndStickyKeys() {
    var router = KeyRouter(keymap: resolve(nil).keymap)
    func actions(_ key: PhysicalKey, _ mods: KeyModifiers, mode: ViewMode = .loupe, t: Double) -> [RoutedAction] {
        let input = KeyInput(keyCode: key.rawValue, modifiers: mods, timestamp: t, character: key == .equal ? "=" : key == .minus ? "-" : nil)
        defer { _ = router.handle(KeyInput(keyCode: key.rawValue, modifiers: mods, isDown: false, timestamp: t + 0.01), mode: mode, focus: .canvas) }
        return router.handle(input, mode: mode, focus: .canvas).actions
    }
    #expect(actions(.equal, [], t: 0) == [.perform("zoom.in")])
    #expect(actions(.minus, [], t: 1) == [.perform("zoom.out")])
    #expect(actions(.equal, [.command], t: 2) == [.perform("zoom.in")])
    #expect(actions(.equal, [.command, .shift], t: 3) == [.perform("zoom.in")])
    #expect(actions(.minus, [.command], t: 4) == [.perform("zoom.out")])
    // Grid keeps the same keys for its thumbnails.
    #expect(actions(.equal, [], mode: .grid, t: 5) == [.perform("grid.larger")])
    #expect(actions(.equal, [.command], mode: .grid, t: 6) == [.perform("grid.larger")])
    // ⌥-arrows pan, bare arrows still navigate.
    #expect(actions(.leftArrow, [.option], t: 7) == [.perform("pan.left")])
    #expect(actions(.downArrow, [.option, .shift], t: 8) == [.perform("pan.pageDown")])
    #expect(actions(.rightArrow, [], t: 9) == [.perform("nav.next")])
    #expect(actions(.leftArrow, [.option], mode: .grid, t: 10).isEmpty)
    // ⌥Z is sticky zoom, not Z's toggle.
    #expect(actions(.z, [.option], t: 11) == [.perform("zoom.sticky")])
    #expect(actions(.z, [], t: 12) == [.perform("zoom.toggle")])
}

@Test func exifKeysLiveInLoupeOnly() {
    var router = KeyRouter(keymap: resolve(nil).keymap)
    func press(_ key: PhysicalKey, _ mode: ViewMode, _ mods: KeyModifiers = [], at t: Double) -> [RoutedAction] {
        router.handle(KeyInput(keyCode: key.rawValue, modifiers: mods, timestamp: t), mode: mode, focus: .canvas).actions
    }
    #expect(press(.i, .loupe, at: 0) == [.perform("info.cycle")])
    #expect(press(.i, .loupe, [.shift], at: 0) == [.perform("info.histogram")])   // M-17
    #expect(press(.i, .grid, at: 1).isEmpty)
    // The inspector opens from every mode; the focus command too (M-18).
    for mode in [ViewMode.grid, .loupe] {
        #expect(press(.i, mode, [.command, .option], at: 1) == [.perform("info.inspector")])
        #expect(press(.i, mode, [.command, .control], at: 1) == [.perform("info.inspectorFocus")])
    }
    #expect(press(.upArrow, .loupe, at: 2) == [.perform("info.fieldPrevious")])
    #expect(press(.c, .loupe, [.command], at: 3) == [.perform("info.copy")])
    #expect(press(.c, .grid, [.command], at: 4).isEmpty)
}
