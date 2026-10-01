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
        Command("cull.reject", "Reject", menu: .init(.photo, group: 1), modes: [.loupe], keys: [Shortcut(.position(.x))]),
    ])
    #expect(table.groups(in: .photo).last?.map(\.id) == ["cull.reject"])
    let r = resolve(nil, table: table)
    #expect(keys(r, "cull.reject") == [Shortcut(.position(.x))])
    var router = KeyRouter(keymap: r.keymap)
    let result = router.handle(KeyInput(keyCode: PhysicalKey.x.rawValue, timestamp: 0), mode: .loupe, focus: .canvas)
    #expect(result.actions == [.perform("cull.reject")])
    // Its modes carry over to the key.
    let grid = router.handle(KeyInput(keyCode: PhysicalKey.x.rawValue, timestamp: 1), mode: .grid, focus: .canvas)
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
