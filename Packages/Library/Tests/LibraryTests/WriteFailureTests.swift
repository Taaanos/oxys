import Foundation
import Sidecar
import Testing
@testable import Library

@Suite @MainActor struct WriteFailureTests {
    private func open(_ folder: TempFolder) async -> FolderModel {
        let model = FolderModel()
        model.open(folder.url)
        for _ in 0..<500 where model.content != .photos || model.isReadingSidecars || model.isReadingCaptureTimes {
            try? await Task.sleep(for: .milliseconds(10))
        }
        try? await Task.sleep(for: .milliseconds(50))
        return model
    }

    private func lock(_ folder: TempFolder) { chmod(folder.url.path, 0o555) }
    private func unlock(_ folder: TempFolder) { chmod(folder.url.path, 0o755) }

    private func waitUntil(_ condition: () -> Bool) async -> Bool {
        let clock = ContinuousClock(), end = clock.now + .seconds(3)
        while !condition(), clock.now < end { try? await Task.sleep(for: .milliseconds(20)) }
        return condition()
    }

    @Test func aReadOnlyFolderShowsTheBannerOnOpen() async throws {
        let folder = try TempFolder(); defer { unlock(folder); folder.remove() }
        try folder.add("a.ARW")
        lock(folder)
        let model = await open(folder)
        #expect(model.isReadOnly)
        #expect(model.banner == .readOnly)
        model.dismissBanner()
        #expect(model.banner == nil)
    }

    @Test func aWritableFolderHasNoBanner() async throws {
        let folder = try TempFolder(); defer { folder.remove() }
        try folder.add("a.ARW")
        let model = await open(folder)
        #expect(!model.isReadOnly && model.banner == nil)
    }

    @Test func decisionsSurviveFailedWritesAndAreMarkedUnsaved() async throws {
        let folder = try TempFolder(); defer { unlock(folder); folder.remove() }
        try folder.add("a.ARW"); try folder.add("b.ARW")
        lock(folder)
        let model = await open(folder)
        model.apply(.setRating(4)); model.move(.next); model.apply(.toggleReject)
        model.flushSidecarWrites()
        #expect(await waitUntil { model.unsavedCount == 2 })
        #expect(model.photos.map { $0.decision.rating } == [4, -1])
        #expect(model.photos.allSatisfy { $0.sidecar.unsaved })
        #expect(model.photos[0].sidecar.notes.first?.hasPrefix("Not saved yet") == true)
        #expect(model.hasUnsavedDecisions)
        guard case .writeFailed = model.banner else { Issue.record("expected failure banner"); return }
        #expect(!FileManager.default.fileExists(atPath: folder.url.appendingPathComponent("a.xmp").path))
    }

    @Test func retryWritesTheDecisionsOnceTheFolderIsWritableAgain() async throws {
        let folder = try TempFolder(); defer { unlock(folder); folder.remove() }
        try folder.add("a.ARW")
        lock(folder)
        let model = await open(folder)
        model.apply(.setRating(3)); model.flushSidecarWrites()
        #expect(await waitUntil { model.unsavedCount == 1 })
        unlock(folder)
        model.retryUnsaved(); model.flushSidecarWrites()
        #expect(await waitUntil { model.unsavedCount == 0 && !model.isReadOnly })
        #expect(!model.hasUnsavedDecisions)
        let props = try XMPReader.parse(Data(contentsOf: folder.url.appendingPathComponent("a.xmp")))
        #expect(props.rating == 3)
        #expect(model.banner == nil)
    }

    @Test func aNewerDecisionIsNotOverwrittenByTheRetry() async throws {
        let folder = try TempFolder(); defer { unlock(folder); folder.remove() }
        try folder.add("a.ARW")
        lock(folder)
        let model = await open(folder)
        model.apply(.setRating(3)); model.flushSidecarWrites()
        #expect(await waitUntil { model.unsavedCount == 1 })
        unlock(folder)
        model.apply(.setRating(5)); model.retryUnsaved(); model.flushSidecarWrites()
        #expect(await waitUntil { model.unsavedCount == 0 })
        let props = try XMPReader.parse(Data(contentsOf: folder.url.appendingPathComponent("a.xmp")))
        #expect(props.rating == 5)
    }

    @Test func saveDecisionsToAnotherFolderWritesSidecarsWithTheSameNames() async throws {
        let folder = try TempFolder(); defer { unlock(folder); folder.remove() }
        let elsewhere = try TempFolder(); defer { elsewhere.remove() }
        try folder.add("a.ARW"); try folder.add("b.ARW")
        lock(folder)
        let model = await open(folder)
        model.apply(.setRating(2)); model.apply(.toggleLabel(.green)); model.move(.next); model.apply(.setRating(5))
        model.flushSidecarWrites()
        #expect(await waitUntil { model.unsavedCount == 2 })
        let saved = await model.saveUnsaved(to: elsewhere.url)
        #expect(saved == 2)
        #expect(model.unsavedCount == 0)
        let a = try XMPReader.parse(Data(contentsOf: elsewhere.url.appendingPathComponent("a.xmp")))
        let b = try XMPReader.parse(Data(contentsOf: elsewhere.url.appendingPathComponent("b.xmp")))
        #expect(a == XMPProperties(rating: 2, label: "Green"))
        #expect(b.rating == 5)
        #expect(model.banner == .savedCopy(elsewhere.url, count: 2))
        #expect(model.photos.allSatisfy { !$0.sidecar.unsaved })
    }

    @Test func aFolderThatVanishesMidSessionKeepsEveryDecisionInMemory() async throws {
        let folder = try TempFolder()
        try folder.add("a.ARW")
        let model = await open(folder)
        folder.remove()
        model.apply(.setRating(4)); model.flushSidecarWrites()
        #expect(await waitUntil { model.unsavedCount == 1 })
        #expect(model.photos.first?.decision.rating == 4)
        #expect(model.hasUnsavedDecisions)
    }
}
