import Foundation
import Sidecar
import Testing
@testable import Library

@Suite @MainActor struct SidecarWriteIntegrationTests {
    private func open(_ folder: TempFolder) async -> FolderModel {
        let model = FolderModel()
        model.open(folder.url)
        for _ in 0..<500 where model.content != .photos || model.isReadingSidecars || model.isReadingCaptureTimes {
            try? await Task.sleep(for: .milliseconds(10))
        }
        try? await Task.sleep(for: .milliseconds(50))
        for _ in 0..<500 where model.isReadingSidecars || model.isReadingCaptureTimes {
            try? await Task.sleep(for: .milliseconds(10))
        }
        return model
    }

    private func props(_ name: String, in folder: TempFolder) throws -> XMPProperties {
        try XMPReader.parse(Data(contentsOf: folder.url.appendingPathComponent(name)))
    }

    @Test func aDecisionCreatesASidecarAndLaterOnesPatchIt() async throws {
        let folder = try TempFolder(); defer { folder.remove() }
        try folder.add("a.ARW")
        let model = await open(folder)
        model.apply(.setRating(3)); model.apply(.toggleLabel(.red))
        model.flushSidecarWrites()
        #expect(try props("a.xmp", in: folder) == XMPProperties(rating: 3, label: "Red"))
        model.apply(.toggleLabel(.red)); model.apply(.toggleReject)
        model.flushSidecarWrites()
        #expect(try props("a.xmp", in: folder) == XMPProperties(rating: -1, label: nil))
        #expect(model.photos[0].sidecar.file?.lastPathComponent == "a.xmp")
    }

    @Test func foreignDataInAnExistingSidecarSurvives() async throws {
        let folder = try TempFolder(); defer { folder.remove() }
        try folder.add("a.ARW")
        let original = """
            <x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
            <rdf:Description rdf:about="" xmlns:xmp="http://ns.adobe.com/xap/1.0/" xmlns:crs="http://ns.adobe.com/camera-raw-settings/1.0/" crs:Exposure2012="+0.50" xmp:Rating="1"/>
            </rdf:RDF></x:xmpmeta>
            """
        try Data(original.utf8).write(to: folder.url.appendingPathComponent("a.xmp"))
        let model = await open(folder)
        model.apply(.setRating(4))
        model.flushSidecarWrites()
        let out = String(decoding: try Data(contentsOf: folder.url.appendingPathComponent("a.xmp")), as: UTF8.self)
        #expect(out.contains(#"crs:Exposure2012="+0.50""#))
        #expect(try props("a.xmp", in: folder).rating == 4)
    }

    @Test func aMalformedSidecarIsNeverOverwritten() async throws {
        let folder = try TempFolder(); defer { folder.remove() }
        try folder.add("a.ARW")
        let bad = Data("<rdf:RDF".utf8)
        try bad.write(to: folder.url.appendingPathComponent("a.xmp"))
        let model = await open(folder)
        model.apply(.setRating(5))
        model.flushSidecarWrites()
        #expect(try Data(contentsOf: folder.url.appendingPathComponent("a.xmp")) == bad)
        #expect(model.photos[0].decision.rating == 5)
    }

    @Test func aCustomLabelStaysUntilTheUserSetsANewOne() async throws {
        let folder = try TempFolder(); defer { folder.remove() }
        try folder.add("a.ARW")
        try Data(#"<x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#"><rdf:Description xmlns:xmp="http://ns.adobe.com/xap/1.0/" xmp:Rating="2" xmp:Label="Select"/></rdf:RDF></x:xmpmeta>"#.utf8)
            .write(to: folder.url.appendingPathComponent("a.xmp"))
        let model = await open(folder)
        model.apply(.setRating(3)); model.flushSidecarWrites()
        #expect(try props("a.xmp", in: folder) == XMPProperties(rating: 3, label: "Select"))
        model.apply(.toggleLabel(.green)); model.flushSidecarWrites()
        #expect(try props("a.xmp", in: folder) == XMPProperties(rating: 3, label: "Green"))
        model.apply(.toggleLabel(.green)); model.flushSidecarWrites()
        #expect(try props("a.xmp", in: folder).label == nil)
    }

    @Test func anExistingFullNameSidecarIsUsedNotDuplicated() async throws {
        let folder = try TempFolder(); defer { folder.remove() }
        try folder.add("a.ARW")
        try Data(#"<x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#"><rdf:Description xmlns:xmp="http://ns.adobe.com/xap/1.0/" xmp:Rating="2"/></rdf:RDF></x:xmpmeta>"#.utf8)
            .write(to: folder.url.appendingPathComponent("a.ARW.xmp"))
        let model = await open(folder)
        model.apply(.setRating(5)); model.flushSidecarWrites()
        #expect(try props("a.ARW.xmp", in: folder).rating == 5)
        #expect(!FileManager.default.fileExists(atPath: folder.url.appendingPathComponent("a.xmp").path))
    }

    @Test func unchangedDecisionsWriteNothing() async throws {
        let folder = try TempFolder(); defer { folder.remove() }
        try folder.add("a.ARW")
        let model = await open(folder)
        model.apply(.setRating(0)); model.flushSidecarWrites()
        #expect(!FileManager.default.fileExists(atPath: folder.url.appendingPathComponent("a.xmp").path))
    }
}
