import Foundation
import Sidecar
import Testing
@testable import Library

@Suite @MainActor struct OutsideChangeTests {
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

    private func xmp(rating: Int, extra: String = "") -> Data {
        Data("""
            <x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
            <rdf:Description rdf:about="" xmlns:xmp="http://ns.adobe.com/xap/1.0/" xmlns:crs="http://ns.adobe.com/camera-raw-settings/1.0/" \(extra) xmp:Rating="\(rating)"/>
            </rdf:RDF></x:xmpmeta>
            """.utf8)
    }

    private func waitUntil(_ timeout: Duration = .seconds(3), _ condition: () -> Bool) async -> Bool {
        let clock = ContinuousClock(), end = clock.now + timeout
        while !condition(), clock.now < end { try? await Task.sleep(for: .milliseconds(20)) }
        return condition()
    }

    @Test func aRewrittenSidecarShowsUpOnScreenWithinASecond() async throws {
        let folder = try TempFolder(); defer { folder.remove() }
        try folder.add("a.ARW")
        let model = await open(folder)
        #expect(model.photos[0].decision.rating == 0)
        let started = ContinuousClock.now
        try xmp(rating: 4).write(to: folder.url.appendingPathComponent("a.xmp"))
        #expect(await waitUntil(.seconds(1)) { model.photos[0].decision.rating == 4 })
        #expect(started.duration(to: .now) < .seconds(1))
        #expect(model.photos[0].sidecar.file?.lastPathComponent == "a.xmp")
    }

    @Test func ourOwnWritesAreRecognisedAndAnOutsideEditIsNot() async throws {
        let folder = try TempFolder(); defer { folder.remove() }
        try folder.add("a.ARW")
        let queue = SidecarWriteQueue()
        let target = SidecarTarget(primary: folder.url.appendingPathComponent("a.xmp"))
        queue.submit(SidecarEdit(rating: 3, label: .remove), to: target)
        queue.flush()
        #expect(queue.isOwnWrite(target.primary))
        #expect(!queue.hasPendingWrite(for: target.primary))
        try xmp(rating: 5).write(to: target.primary)
        #expect(!queue.isOwnWrite(target.primary))
        #expect(!queue.isOwnWrite(folder.url.appendingPathComponent("never-written.xmp")))
    }

    @Test func anOutsideEditBetweenTwoOfOurWritesKeepsBothSetsOfChanges() async throws {
        let folder = try TempFolder(); defer { folder.remove() }
        try folder.add("a.ARW")
        let model = await open(folder)
        model.apply(.setRating(2)); model.flushSidecarWrites()
        let file = folder.url.appendingPathComponent("a.xmp")
        var text = String(decoding: try Data(contentsOf: file), as: UTF8.self)
        text = text.replacingOccurrences(of: "xmp:Rating", with: #"xmlns:crs="http://ns.adobe.com/camera-raw-settings/1.0/" crs:Exposure2012="+0.50" xmp:Rating"#)
        try Data(text.utf8).write(to: file)
        model.apply(.setRating(5)); model.flushSidecarWrites()
        let out = String(decoding: try Data(contentsOf: file), as: UTF8.self)
        #expect(out.contains(#"crs:Exposure2012="+0.50""#))
        #expect(try XMPReader.parse(Data(out.utf8)).rating == 5)
    }

    @Test func aChangeToAPhotoWithNoPendingEditReplacesTheDecision() async throws {
        let folder = try TempFolder(); defer { folder.remove() }
        try folder.add("a.ARW"); try folder.add("b.ARW")
        try xmp(rating: 1).write(to: folder.url.appendingPathComponent("a.xmp"))
        let model = await open(folder)
        #expect(model.photos[0].decision.rating == 1)
        try xmp(rating: -1).write(to: folder.url.appendingPathComponent("a.xmp"))
        model.handleChanges(["a.xmp"])
        #expect(await waitUntil { model.photos[0].decision.isReject })
    }

    @Test func aMalformedRewriteKeepsTheDecisionAndBlocksWrites() async throws {
        let folder = try TempFolder(); defer { folder.remove() }
        try folder.add("a.ARW")
        try xmp(rating: 3).write(to: folder.url.appendingPathComponent("a.xmp"))
        let model = await open(folder)
        try Data("<rdf:RDF".utf8).write(to: folder.url.appendingPathComponent("a.xmp"))
        model.handleChanges(["a.xmp"])
        #expect(await waitUntil { model.photos[0].sidecar.problem != nil })
        #expect(model.photos[0].decision.rating == 3)
    }

    @Test func removedPhotosLeaveTheViewAndNewOnesAreOnlyCounted() async throws {
        let folder = try TempFolder(); defer { folder.remove() }
        for name in ["a.ARW", "b.ARW", "c.ARW"] { try folder.add(name) }
        let model = await open(folder)
        model.move(.next)
        #expect(model.currentURL?.lastPathComponent == "b.ARW")
        try FileManager.default.removeItem(at: folder.url.appendingPathComponent("b.ARW"))
        try folder.add("d.ARW")
        model.handleChanges(["b.ARW", "d.ARW", ".hidden.ARW", "notes.txt"])
        #expect(model.photos.map(\.name) == ["a.ARW", "c.ARW"])
        #expect(model.currentURL?.lastPathComponent == "c.ARW")
        #expect(model.newFileCount == 1)
    }

    @Test func ourOwnWriteEchoIsNotReadBack() async throws {
        let folder = try TempFolder(); defer { folder.remove() }
        try folder.add("a.ARW")
        let model = await open(folder)
        model.apply(.setRating(3)); model.flushSidecarWrites()
        model.apply(.setRating(4))      // in memory; the echo of the first write must not undo it
        model.handleChanges(["a.xmp"])
        try? await Task.sleep(for: .milliseconds(100))
        #expect(model.photos[0].decision.rating == 4)
    }
}
