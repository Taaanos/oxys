import Foundation
import Testing
@testable import Library

/// A throwaway folder of empty files.
struct TempFolder {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("oxys-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    @discardableResult
    func add(_ path: String, modified: Date? = nil) throws -> URL {
        let file = url.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: file)
        if let modified { try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: file.path) }
        return file
    }

    func remove() { try? FileManager.default.removeItem(at: url) }
}

@Suite struct FolderScannerTests {
    @Test func listsSupportedFormatsInAnyCase() throws {
        let folder = try TempFolder(); defer { folder.remove() }
        for name in ["a.ARW", "b.cr2", "c.Cr3", "d.NEF", "e.raf", "f.DNG", "g.orf", "h.rw2", "i.pef", "j.jpg", "k.JPEG", "l.heic", "m.TIF", "n.tiff"] {
            try folder.add(name)
        }
        let result = try FolderScanner.scan(folder.url)
        #expect(result.photos.count == 14)
        #expect(result.photos.first { $0.name == "k.JPEG" }?.format == .jpeg)
        #expect(result.photos.first { $0.name == "c.Cr3" }?.format == .cr3)
    }

    @Test func skipsHiddenAppleDoubleSidecarsAndUnsupported() throws {
        let folder = try TempFolder(); defer { folder.remove() }
        try folder.add("keep.ARW")
        try folder.add(".hidden.ARW")
        try folder.add("._keep.ARW")        // AppleDouble from an exFAT card
        try folder.add("keep.ARW.xmp")
        try folder.add("keep.xmp")
        try folder.add("notes.txt")
        try folder.add("movie.mov")
        try folder.add("noextension")
        try FileManager.default.createDirectory(at: folder.url.appendingPathComponent("folder.ARW"), withIntermediateDirectories: false)
        let result = try FolderScanner.scan(folder.url)
        #expect(result.photos.map(\.name) == ["keep.ARW"])
    }

    @Test func recordsSizeAndModificationDate() throws {
        let folder = try TempFolder(); defer { folder.remove() }
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        try folder.add("a.jpg", modified: date)
        let photo = try #require(try FolderScanner.scan(folder.url).photos.first)
        #expect(photo.fileSize == 1)
        #expect(photo.modificationDate == date)
        #expect(photo.captureTime == nil)
    }

    @Test func sortsByTimeThenNumericFilename() throws {
        let folder = try TempFolder(); defer { folder.remove() }
        let same = Date(timeIntervalSince1970: 1_700_000_000)
        try folder.add("IMG_10.jpg", modified: same)
        try folder.add("IMG_2.jpg", modified: same)
        try folder.add("IMG_1.jpg", modified: same.addingTimeInterval(60))
        let names = try FolderScanner.scan(folder.url).photos.map(\.name)
        #expect(names == ["IMG_2.jpg", "IMG_10.jpg", "IMG_1.jpg"])
    }

    @Test func captureTimeBeatsModificationDateAndMissingFallsBack() {
        let url = URL(fileURLWithPath: "/x/a.jpg")
        let old = Date(timeIntervalSince1970: 100), new = Date(timeIntervalSince1970: 900)
        let shot = Photo(url: url, format: .jpeg, fileSize: 1, modificationDate: new, captureTime: old)
        let screenshot = Photo(url: url, format: .jpeg, fileSize: 1, modificationDate: new)
        #expect(shot.sortDate == old)
        #expect(screenshot.sortDate == new)
    }

    @Test func emptyFolderHasNoPhotosAndNoHint() throws {
        let folder = try TempFolder(); defer { folder.remove() }
        let result = try FolderScanner.scan(folder.url)
        #expect(result.photos.isEmpty && !result.subfolderHasPhotos)
    }

    @Test func hintsAtCardLayoutSubfolders() throws {
        let folder = try TempFolder(); defer { folder.remove() }
        try folder.add("DCIM/100MSDCF/DSC00001.ARW")
        let result = try FolderScanner.scan(folder.url)
        #expect(result.photos.isEmpty && result.subfolderHasPhotos)
    }

    @Test func noHintWhenTheFolderItselfHasPhotos() throws {
        let folder = try TempFolder(); defer { folder.remove() }
        try folder.add("a.ARW")
        try folder.add("sub/b.ARW")
        let result = try FolderScanner.scan(folder.url)
        #expect(result.photos.count == 1 && !result.subfolderHasPhotos)
    }

    @Test func unreadableFolderThrows() {
        #expect(throws: (any Error).self) { try FolderScanner.scan(URL(fileURLWithPath: "/nonexistent-oxys-folder")) }
    }

    @Test func scanWritesNothing() async throws {
        let folder = try TempFolder(); defer { folder.remove() }
        try folder.add("a.ARW"); try folder.add("sub/b.ARW")
        _ = try FolderScanner.scan(folder.url)
        _ = await FolderScanner.captureTimes(for: try FolderScanner.scan(folder.url).photos)
        let names = try FileManager.default.subpathsOfDirectory(atPath: folder.url.path).sorted()
        #expect(names == ["a.ARW", "sub", "sub/b.ARW"])
    }

    @Test func captureTimesKeepInputOrderAndTolerateUnreadableFiles() async throws {
        let folder = try TempFolder(); defer { folder.remove() }
        for i in 0..<30 { try folder.add("f\(i).ARW") }   // not real images: every read fails, none may crash or reorder
        let photos = try FolderScanner.scan(folder.url).photos
        let times = await FolderScanner.captureTimes(for: photos)
        #expect(times.count == 30 && times.allSatisfy { $0 == nil })
    }
}

@Suite @MainActor struct FolderModelTests {
    func waitUntil(_ model: FolderModel, _ done: () -> Bool) async {
        for _ in 0..<500 where !done() { try? await Task.sleep(for: .milliseconds(10)) }
    }

    @Test func publishesListThenFinishes() async throws {
        let folder = try TempFolder(); defer { folder.remove() }
        try folder.add("a.jpg"); try folder.add("b.jpg")
        let model = FolderModel()
        model.open(folder.url)
        #expect(model.content == .opening(folder.url))
        await waitUntil(model) { model.content == .photos && !model.isReadingCaptureTimes }
        #expect(model.photos.count == 2)
    }

    @Test func emptyAndMissingFoldersExplainThemselves() async throws {
        let folder = try TempFolder(); defer { folder.remove() }
        let model = FolderModel()
        model.open(folder.url)
        await waitUntil(model) { model.content != .opening(folder.url) }
        #expect(model.content == .empty(hasSubfolderPhotos: false))
        model.open(URL(fileURLWithPath: "/nonexistent-oxys-folder"))
        await waitUntil(model) { if case .failed = model.content { true } else { false } }
        if case .failed = model.content {} else { Issue.record("expected .failed, got \(model.content)") }
    }

    @Test func openingAnotherFolderReplacesTheFirst() async throws {
        let one = try TempFolder(), two = try TempFolder()
        defer { one.remove(); two.remove() }
        try one.add("one.jpg"); try two.add("two.jpg"); try two.add("two2.jpg")
        let model = FolderModel()
        model.open(one.url)
        model.open(two.url)
        await waitUntil(model) { model.content == .photos && !model.isReadingCaptureTimes }
        #expect(model.folder == two.url)
        #expect(model.photos.map(\.name).sorted() == ["two.jpg", "two2.jpg"])
    }
}

@Suite @MainActor struct FolderNavigationTests {
    private func openFolder(names: [String]) async throws -> FolderModel {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("nav-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for name in names { try Data([0]).write(to: dir.appendingPathComponent(name)) }
        let model = FolderModel()
        model.open(dir)
        for _ in 0..<500 where model.isReadingCaptureTimes || model.content != .photos {
            try await Task.sleep(for: .milliseconds(10))
        }
        return model
    }

    @Test func startsOnTheFirstPhotoAndStopsAtTheEnds() async throws {
        let model = try await openFolder(names: ["a.jpg", "b.jpg", "c.jpg"])
        #expect(model.currentIndex == 0)
        #expect(model.move(.previous) == false)
        #expect(model.move(.next))
        #expect(model.currentPhoto?.name == "b.jpg")
        #expect(model.move(.last))
        #expect(model.currentPhoto?.name == "c.jpg")
        #expect(model.move(.next) == false)
        #expect(model.move(.first))
        #expect(model.currentIndex == 0)
        #expect(model.move(.first) == false)
    }

    @Test func movingInAnEmptyModelDoesNothing() {
        let model = FolderModel()
        #expect(model.move(.next) == false)
        #expect(model.currentPhoto == nil)
    }
}
