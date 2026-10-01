import Foundation
import Sidecar
import Testing
@testable import Library

private func xmp(_ attrs: String) -> String {
    """
    <x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">\
    <rdf:Description xmlns:xmp="http://ns.adobe.com/xap/1.0/" \(attrs)/></rdf:RDF></x:xmpmeta>
    """
}

@Suite @MainActor struct SidecarReadTests {
    private func open(_ folder: TempFolder, naming: SidecarNaming = .stem) async -> FolderModel {
        let model = FolderModel()
        model.sidecarNaming = naming
        model.open(folder.url)
        for _ in 0..<500 where model.content != .photos || model.isReadingSidecars || model.isReadingCaptureTimes {
            try? await Task.sleep(for: .milliseconds(10))
        }
        // The task flags flip after the first suspension; one more settle covers a not-yet-started read.
        try? await Task.sleep(for: .milliseconds(50))
        for _ in 0..<500 where model.isReadingSidecars || model.isReadingCaptureTimes {
            try? await Task.sleep(for: .milliseconds(10))
        }
        return model
    }

    private func write(_ text: String, _ name: String, in folder: TempFolder) throws {
        try Data(text.utf8).write(to: folder.url.appendingPathComponent(name))
    }

    @Test func readsDecisionsFromBothNamingStyles() async throws {
        let folder = try TempFolder(); defer { folder.remove() }
        for name in ["a.ARW", "b.ARW", "c.ARW", "d.ARW"] { try folder.add(name) }
        try write(xmp(#"xmp:Rating="4" xmp:Label="Blue""#), "a.xmp", in: folder)
        try write(xmp(#"xmp:Rating="-1""#), "b.ARW.xmp", in: folder)
        try write(xmp(#"xmp:Rating="2" xmp:Label="Select""#), "c.xmp", in: folder)
        let model = await open(folder)
        let byName = Dictionary(uniqueKeysWithValues: model.photos.map { ($0.name, $0) })
        #expect(byName["a.ARW"]?.decision == Decision(rating: 4, label: .blue))
        #expect(byName["b.ARW"]?.decision.isReject == true)
        #expect(byName["b.ARW"]?.sidecar.file?.lastPathComponent == "b.ARW.xmp")
        // A custom label is kept as read and shown, not mapped to one of ours.
        #expect(byName["c.ARW"]?.decision == Decision(rating: 2, label: nil))
        #expect(byName["c.ARW"]?.sidecar.unknownLabel == "Select")
        #expect(byName["d.ARW"]?.decision == Decision.none)
        #expect(byName["d.ARW"]?.sidecar.file == nil)
        #expect(byName["d.ARW"]?.sidecar.isRead == true)
    }

    @Test func malformedSidecarGivesNoDecisionAndAProblem() async throws {
        let folder = try TempFolder(); defer { folder.remove() }
        try folder.add("a.ARW")
        try write("<rdf:RDF", "a.xmp", in: folder)
        let model = await open(folder)
        let photo = try #require(model.photos.first)
        #expect(photo.decision == Decision.none)
        #expect(photo.sidecar.problem != nil)
        #expect(photo.sidecar.file?.lastPathComponent == "a.xmp")
    }

    @Test func configuredStyleWinsWhenBothExist() async throws {
        let folder = try TempFolder(); defer { folder.remove() }
        try folder.add("a.ARW")
        try write(xmp(#"xmp:Rating="1""#), "a.xmp", in: folder)
        try write(xmp(#"xmp:Rating="5""#), "a.ARW.xmp", in: folder)
        let stem = await open(folder, naming: .stem)
        #expect(stem.photos.first?.decision.rating == 1)
        #expect(stem.photos.first?.sidecar.alsoPresent?.lastPathComponent == "a.ARW.xmp")
        let full = await open(folder, naming: .fullName)
        #expect(full.photos.first?.decision.rating == 5)
    }

    @Test func aDecisionMadeBeforeTheReadFinishesIsKept() async throws {
        let folder = try TempFolder(); defer { folder.remove() }
        try folder.add("a.ARW")
        try write(xmp(#"xmp:Rating="1""#), "a.xmp", in: folder)
        let model = FolderModel()
        model.open(folder.url)
        for _ in 0..<500 where model.content != .photos { try await Task.sleep(for: .milliseconds(5)) }
        model.apply(.setRating(5))
        for _ in 0..<500 where model.photos.first?.sidecar.isRead != true { try await Task.sleep(for: .milliseconds(5)) }
        #expect(model.photos.first?.decision.rating == 5)
    }
}
