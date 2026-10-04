import Foundation
import Testing
@testable import Commands

private func fixture(_ id: String, _ json: String) throws -> KeymapPreset {
    let file = try KeymapFile.decode(Data(json.utf8))
    return KeymapPreset(id: id, name: file.name ?? id, file: file)
}

@Test func everyShortcutRoundTripsThroughAFileEntry() throws {
    var shortcuts = PhysicalKey.allCases.flatMap { [Shortcut(.position($0)), Shortcut(.position($0), [.command, .shift, .option, .control])] }
    shortcuts += ["[", "]", "?", "=", "-", "\\"].map { Shortcut(.character(Character($0))) }
    shortcuts.append(Shortcut(.character("="), [.command]))
    for shortcut in shortcuts {
        let entry = KeymapFile.Entry(shortcut)
        #expect(try entry.shortcut().get() == shortcut)
    }
}

@Test func anEntryWithNoModifiersLeavesTheFieldOut() throws {
    let file = KeymapFile(bindings: ["nav.next": [KeymapFile.Entry(Shortcut(.position(.d)))]])
    let text = try #require(String(data: file.encoded(), encoding: .utf8))
    #expect(!text.contains("modifiers"))
    #expect(!text.contains("preset"))
    #expect(text.contains("\"position\" : \"d\""))
}

@Test func theFileRoundTripsAndKeepsKeysInOrder() throws {
    let file = KeymapFile(preset: "fastrawviewer", bindings: [
        "zoom.in": [KeymapFile.Entry(Shortcut(.character("="), [.command]))],
        "nav.last": [],
        "cull.reject": [KeymapFile.Entry(Shortcut(.position(.q))), KeymapFile.Entry(Shortcut(.position(.x), [.shift]))],
    ])
    let data = try file.encoded()
    #expect(try KeymapFile.decode(data) == file)
    let text = try #require(String(data: data, encoding: .utf8))
    let order = ["cull.reject", "nav.last", "zoom.in"].compactMap { text.range(of: $0)?.lowerBound }
    #expect(order == order.sorted())
}

@Test func theWrittenFileResolvesToTheKeysThatWentIn() throws {
    var editor = KeymapEditor()
    editor.assign(Shortcut(.position(.q)), to: "cull.reject")
    let r = Keymap.resolve(table: .standard, userFile: try editor.file.encoded())
    #expect(r.problems.isEmpty)
    #expect(r.keymap.shortcuts(for: "cull.reject") == [Shortcut(.position(.x)), Shortcut(.position(.q))])
}

@Test func aPresetSitsBetweenTheDefaultsAndTheFile() throws {
    let preset = try fixture("test", #"{"version":1,"name":"Test","bindings":{"cull.reject":[{"position":"q"}],"nav.next":[{"position":"d"}]}}"#)
    let user = #"{"version":1,"preset":"test","bindings":{"nav.next":[{"position":"f"}]}}"#
    let r = Keymap.resolve(table: .standard, userFile: Data(user.utf8), presets: [preset])
    #expect(r.problems.isEmpty)
    // The preset changes Reject; the file wins over the preset for Next Photo; the rest stays Default.
    #expect(r.keymap.shortcuts(for: "cull.reject") == [Shortcut(.position(.q))])
    #expect(r.keymap.shortcuts(for: "nav.next") == [Shortcut(.position(.f))])
    #expect(r.keymap.shortcuts(for: "nav.previous") == [Shortcut(.position(.leftArrow))])
    // The twin follows a preset's key too.
    #expect(r.keymap.bindings.contains { $0.command == "cull.reject" && $0.advances && $0.key == .position(.q) })
}

@Test func aFileThatNamesNoPresetIgnoresThem() throws {
    let preset = try fixture("test", #"{"version":1,"bindings":{"cull.reject":[{"position":"q"}]}}"#)
    let r = Keymap.resolve(table: .standard, userFile: Data(#"{"version":1,"bindings":{}}"#.utf8), presets: [preset])
    #expect(r.keymap.shortcuts(for: "cull.reject") == [Shortcut(.position(.x))])
}

@Test func anUnknownPresetIsReportedAndTheRestApplies() {
    let r = Keymap.resolve(table: .standard, userFile: Data(#"{"version":1,"preset":"nope","bindings":{"nav.last":[]}}"#.utf8), presets: [])
    #expect(r.problems.count == 1)
    #expect(r.keymap.shortcuts(for: "nav.last").isEmpty)
}

@Test func aBadEntryInAPresetIsReportedUnderThePresetsName() throws {
    let preset = try fixture("test", #"{"version":1,"name":"Test","bindings":{"nope":[{"position":"x"}]}}"#)
    let r = Keymap.resolve(table: .standard, userFile: Data(#"{"version":1,"preset":"test","bindings":{}}"#.utf8), presets: [preset])
    #expect(r.problems == ["Preset Test: unknown command \"nope\"."])
}

@Test func theLoaderReadsJSONFilesAndSkipsTheRest() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: "presets-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try Data(#"{"version":1,"name":"Zeta","bindings":{}}"#.utf8).write(to: directory.appending(path: "zeta.json"))
    try Data(#"{"version":1,"bindings":{}}"#.utf8).write(to: directory.appending(path: "alpha.json"))
    try Data("not json".utf8).write(to: directory.appending(path: "broken.json"))
    try Data("{}".utf8).write(to: directory.appending(path: "notes.txt"))
    let presets = KeymapPreset.load(from: directory)
    #expect(presets.map(\.id) == ["alpha", "zeta"])
    #expect(presets.map(\.name) == ["alpha", "Zeta"])
}

@Test func everyBundledPresetResolvesWithNoProblems() {
    for preset in KeymapPreset.bundled {
        let r = Keymap.resolve(table: .standard, file: KeymapFile(preset: preset.id))
        #expect(r.problems.isEmpty, "\(preset.id): \(r.problems)")
    }
}
