import Foundation
import Testing
@testable import Library

@Test func presetsAreLightroomRawTherapeeAndArt() {
    #expect(EditorList().all.map(\.name) == ["Lightroom Classic", "RawTherapee", "ART"])
    #expect(ExternalEditor.presets.allSatisfy { $0.isPreset })
}

@Test func defaultFallsBackToFirstInstalled() {
    let list = EditorList()
    let art = list.resolvedDefault { $0.id == "art" }
    let none = list.resolvedDefault { _ in false }
    let first = list.resolvedDefault { _ in true }
    #expect(art?.id == "art")
    #expect(none == nil)
    #expect(first?.id == "lightroom-classic")
}

@Test func chosenDefaultWinsWhenInstalledAndFallsBackWhenMissing() {
    let list = EditorList(defaultID: "rawtherapee")
    let chosen = list.resolvedDefault { _ in true }
    let fallback = list.resolvedDefault { $0.id == "art" }
    #expect(chosen?.id == "rawtherapee")
    #expect(fallback?.id == "art")
}

@Test func addedEditorIsListedOnceAndRemovalClearsDefault() {
    var list = EditorList()
    let affinity = ExternalEditor.custom(name: "Affinity", bundleID: nil, path: "/Applications/Affinity.app")
    list.add(affinity)
    list.add(affinity)
    #expect(list.all.count == 4)
    list.defaultID = affinity.id
    list.remove(id: affinity.id)
    #expect(list.all.count == 3)
    #expect(list.defaultID == nil)
}

@Test func presetsCannotBeRemoved() {
    var list = EditorList(defaultID: "art")
    list.remove(id: "rawtherapee")
    #expect(list.all.count == 3)
    #expect(list.defaultID == "art")
}

@Test func listSurvivesJSON() throws {
    var list = EditorList(defaultID: "art")
    list.add(.custom(name: "X", bundleID: "x.y", path: "/Applications/X.app"))
    let back = try JSONDecoder().decode(EditorList.self, from: JSONEncoder().encode(list))
    #expect(back == list)
}
