import Foundation
import Synchronization
import Testing
@testable import Library

@Suite struct SessionStoreTests {
    private func store(now: @escaping @Sendable () -> Date = { Date() }) -> (SessionStore, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("oxys-sessions-\(UUID().uuidString)")
        return (SessionStore(directory: dir, now: now), dir)
    }

    private func folder() throws -> TempFolder { try TempFolder() }

    @Test func aSavedSessionComesBack() throws {
        let (store, dir) = store(); defer { try? FileManager.default.removeItem(at: dir) }
        let photos = try folder(); defer { photos.remove() }
        var filter = PhotoFilter()
        filter.setMinimumStars(3); filter.labels = [.red]; filter.sortKey = .filename; filter.ascending = false
        let state = SessionState(identity: FolderIdentity(photos.url), mode: "loupe", currentName: "b.ARW", filter: filter,
                                 selected: ["a.ARW", "c.ARW"], selectionAnchor: "a.ARW",
                                 unsaved: [UnsavedDecision(name: "b.ARW", decision: Decision(rating: 4, label: .green))])
        #expect(store.save(state))
        let loaded = try #require(store.load(for: photos.url))
        #expect(loaded.sameContent(as: state))
        #expect(loaded.filter.stars == [3, 4, 5] && loaded.filter.starAnchor == 3)
        #expect(loaded.unsaved.first?.decision == Decision(rating: 4, label: .green))
    }

    @Test func aFolderWithoutASessionGivesNil() throws {
        let (store, dir) = store(); defer { try? FileManager.default.removeItem(at: dir) }
        let photos = try folder(); defer { photos.remove() }
        #expect(store.load(for: photos.url) == nil)
    }

    @Test func aRenamedVolumeFindsTheSameFolderByUUIDAndPlace() throws {
        let (store, dir) = store(); defer { try? FileManager.default.removeItem(at: dir) }
        let photos = try folder(); defer { photos.remove() }
        let now = FolderIdentity(photos.url)
        try #require(now.volumeUUID != nil)
        // The card was called "EOS" when the session was saved: another path, same volume UUID, same place on it.
        let old = FolderIdentity(path: "/Volumes/EOS/" + (now.volumeRelativePath ?? ""), volumeUUID: now.volumeUUID,
                                 volumeRelativePath: now.volumeRelativePath)
        store.save(SessionState(identity: old, currentName: "x.ARW"))
        #expect(store.load(for: photos.url)?.currentName == "x.ARW")
    }

    @Test func aDifferentVolumeAtADifferentPathIsAnotherFolder() throws {
        let (store, dir) = store(); defer { try? FileManager.default.removeItem(at: dir) }
        let photos = try folder(); defer { photos.remove() }
        let now = FolderIdentity(photos.url)
        store.save(SessionState(identity: FolderIdentity(path: "/Volumes/Other/DCIM", volumeUUID: "OTHER-UUID",
                                                         volumeRelativePath: now.volumeRelativePath), currentName: "x.ARW"))
        #expect(store.load(for: photos.url) == nil)
    }

    @Test func aReformattedCardAtTheSamePathKeepsItsSession() throws {
        let (store, dir) = store(); defer { try? FileManager.default.removeItem(at: dir) }
        let photos = try folder(); defer { photos.remove() }
        let now = FolderIdentity(photos.url)
        store.save(SessionState(identity: FolderIdentity(path: now.path, volumeUUID: "OLD-UUID", volumeRelativePath: "elsewhere"),
                                currentName: "x.ARW"))
        #expect(store.load(for: photos.url)?.currentName == "x.ARW")
    }

    @Test func sessionsOlderThanNinetyDaysAreIgnoredAndRemoved() throws {
        let clock = Mutex(Date(timeIntervalSince1970: 1_000_000))
        let (store, dir) = store(now: { clock.withLock { $0 } }); defer { try? FileManager.default.removeItem(at: dir) }
        let photos = try folder(); defer { photos.remove() }
        store.save(SessionState(identity: FolderIdentity(photos.url), savedAt: clock.withLock { $0 }, currentName: "x.ARW"))
        clock.withLock { $0 += 89 * 24 * 3600 }
        #expect(store.load(for: photos.url) != nil)
        clock.withLock { $0 += 2 * 24 * 3600 }
        #expect(store.load(for: photos.url) == nil)
        store.prune()
        #expect((try FileManager.default.contentsOfDirectory(atPath: dir.path)).filter { $0.hasPrefix("s-") }.isEmpty)
    }

    @Test func onlyTheFiveHundredNewestSessionsStay() throws {
        let clock = Mutex(Date(timeIntervalSince1970: 1_000_000))
        let (store, dir) = store(now: { clock.withLock { $0 } }); defer { try? FileManager.default.removeItem(at: dir) }
        for i in 0..<(SessionStore.maxCount + 3) {
            store.save(SessionState(identity: FolderIdentity(path: "/nowhere/\(i)"), savedAt: Date(timeIntervalSince1970: 1_000_000 + Double(i))))
        }
        store.prune()
        let files = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasPrefix("s-") }
        #expect(files.count == SessionStore.maxCount)
        #expect(store.load(for: URL(fileURLWithPath: "/nowhere/0")) == nil)
        #expect(store.load(for: URL(fileURLWithPath: "/nowhere/\(SessionStore.maxCount + 2)")) != nil)
    }

    @Test func theLastFolderIsReopenedOnlyWhileItExists() throws {
        let (store, dir) = store(); defer { try? FileManager.default.removeItem(at: dir) }
        let photos = try folder()
        #expect(store.lastFolder == nil)
        store.save(SessionState(identity: FolderIdentity(photos.url)))
        #expect(store.lastFolder?.standardizedFileURL.path == photos.url.standardizedFileURL.path)
        photos.remove()
        #expect(store.lastFolder == nil)
    }

    @Test func aCorruptOrNewerFileIsIgnored() throws {
        let (store, dir) = store(); defer { try? FileManager.default.removeItem(at: dir) }
        let photos = try folder(); defer { photos.remove() }
        store.save(SessionState(identity: FolderIdentity(photos.url), currentName: "x.ARW"))
        for file in try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) where file.lastPathComponent.hasPrefix("s-") {
            try Data("{ not json".utf8).write(to: file)
        }
        #expect(store.load(for: photos.url) == nil)
    }
}

@Suite @MainActor struct SessionRestoreTests {
    private func waitUntil(_ condition: () -> Bool) async -> Bool {
        let clock = ContinuousClock(), end = clock.now + .seconds(3)
        while !condition(), clock.now < end { try? await Task.sleep(for: .milliseconds(20)) }
        return condition()
    }

    private func open(_ url: URL, restoring: SessionState? = nil) async -> FolderModel {
        let model = FolderModel()
        model.open(url, restoring: restoring)
        _ = await waitUntil { model.content == .photos && !model.isReadingSidecars && !model.isReadingCaptureTimes }
        try? await Task.sleep(for: .milliseconds(50))
        return model
    }

    private func fourPhotos() throws -> TempFolder {
        let folder = try TempFolder()
        for name in ["a.ARW", "b.ARW", "c.ARW", "d.ARW"] { try folder.add(name) }
        return folder
    }

    @Test func sortAndSelectionComeBackButTheFilterDoesNot() async throws {
        let folder = try fourPhotos(); defer { folder.remove() }
        let first = await open(folder.url)
        for (i, stars) in [4, 2, 5, 1].enumerated() { first.setCurrent(index: i); first.apply(.setRating(stars)) }
        first.flushSidecarWrites()
        first.updateFilter { $0.setMinimumStars(4); $0.sortKey = .filename; $0.ascending = false }
        first.click(first.visible[0].url, mode: .replace)
        first.setCurrent(index: 1)
        let saved = try #require(first.sessionState(mode: "loupe"))
        #expect(saved.currentName == "a.ARW" && saved.selected == ["c.ARW"])

        let second = await open(folder.url, restoring: saved)
        #expect(second.filter.stars.isEmpty && !second.filter.hasCriteria)
        #expect(second.filter.sortKey == .filename && !second.filter.ascending)
        #expect(second.visible.map(\.name) == ["d.ARW", "c.ARW", "b.ARW", "a.ARW"])
        #expect(second.currentPhoto?.name == "a.ARW")
        #expect(second.selection.urls.map(\.lastPathComponent) == ["c.ARW"])
    }

    @Test func photosThatDisappearedAreSkipped() async throws {
        let folder = try fourPhotos(); defer { folder.remove() }
        var state = SessionState(identity: FolderIdentity(folder.url), currentName: "gone.ARW", selected: ["b.ARW", "gone.ARW", "d.ARW"],
                                 selectionAnchor: "gone.ARW")
        state.unsaved = [UnsavedDecision(name: "gone.ARW", decision: Decision(rating: 3))]
        let model = await open(folder.url, restoring: state)
        #expect(model.currentPhoto?.name == "a.ARW")
        #expect(model.selection.urls.map(\.lastPathComponent).sorted() == ["b.ARW", "d.ARW"])
        #expect(model.selection.anchor == nil)
    }

    @Test func aSavedFilterIsDroppedOnReopen() async throws {
        let folder = try fourPhotos(); defer { folder.remove() }
        var filter = PhotoFilter(); filter.search = "b"
        let state = SessionState(identity: FolderIdentity(folder.url), filter: filter, selected: ["a.ARW", "b.ARW"])
        let model = await open(folder.url, restoring: state)
        #expect(model.visible.count == 4)
        #expect(model.selection.urls.map(\.lastPathComponent).sorted() == ["a.ARW", "b.ARW"])
    }

    @Test func unsavedDecisionsAreWrittenOnReopen() async throws {
        let folder = try fourPhotos(); defer { folder.remove() }
        let state = SessionState(identity: FolderIdentity(folder.url), savedAt: Date().addingTimeInterval(60),
                                 unsaved: [UnsavedDecision(name: "b.ARW", decision: Decision(rating: 4, label: .red))])
        let model = await open(folder.url, restoring: state)
        model.flushSidecarWrites()
        #expect(model.photos.first { $0.name == "b.ARW" }?.decision == Decision(rating: 4, label: .red))
        #expect(await waitUntil { FileManager.default.fileExists(atPath: folder.url.appendingPathComponent("b.xmp").path) })
        #expect(model.unsavedCount == 0)
    }

    @Test func unsavedDecisionsStayUnsavedWhileTheFolderCannotBeWritten() async throws {
        let folder = try fourPhotos(); defer { chmod(folder.url.path, 0o755); folder.remove() }
        chmod(folder.url.path, 0o555)
        let state = SessionState(identity: FolderIdentity(folder.url), savedAt: Date().addingTimeInterval(60),
                                 unsaved: [UnsavedDecision(name: "b.ARW", decision: Decision(rating: 4))])
        let model = await open(folder.url, restoring: state)
        model.flushSidecarWrites()
        #expect(await waitUntil { model.unsavedCount == 1 })
        #expect(model.sessionState(mode: "grid")?.unsaved.map(\.name) == ["b.ARW"])
    }

    @Test func aSidecarEditedElsewhereSinceTheSaveWins() async throws {
        let folder = try fourPhotos(); defer { folder.remove() }
        try Data("<x:xmpmeta xmlns:x=\"adobe:ns:meta/\"/>".utf8).write(to: folder.url.appendingPathComponent("b.xmp"))
        let state = SessionState(identity: FolderIdentity(folder.url), savedAt: Date().addingTimeInterval(-3600),
                                 unsaved: [UnsavedDecision(name: "b.ARW", decision: Decision(rating: 4))])
        let model = await open(folder.url, restoring: state)
        #expect(model.photos.first { $0.name == "b.ARW" }?.decision.rating != 4)
    }

    @Test func nothingIsSavedWhileARestoreIsStillPending() async throws {
        let folder = try fourPhotos(); defer { folder.remove() }
        let model = FolderModel()
        model.open(folder.url, restoring: SessionState(identity: FolderIdentity(folder.url)))
        #expect(model.sessionState(mode: "grid") == nil)
        _ = await waitUntil { model.content == .photos && !model.isReadingSidecars && !model.isReadingCaptureTimes }
        try? await Task.sleep(for: .milliseconds(50))
        #expect(model.sessionState(mode: "grid") != nil)
    }

    @Test func reloadKeepsTheCurrentPhotoAndSelection() async throws {
        let folder = try fourPhotos(); defer { folder.remove() }
        let model = await open(folder.url)
        model.click(model.photos[1].url, mode: .toggle)
        model.setCurrent(index: 2)
        model.reload()
        _ = await waitUntil { model.content == .photos && !model.isReadingSidecars && !model.isReadingCaptureTimes }
        try? await Task.sleep(for: .milliseconds(50))
        #expect(model.currentPhoto?.name == "c.ARW")
        #expect(model.selection.urls.map(\.lastPathComponent) == ["b.ARW"])
    }
}
