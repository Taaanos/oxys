import Foundation
import Sidecar
import Testing
@testable import Library

@Suite struct RawJpegPairingScanTests {
    @Test func aPairIsOneFrameWithTheRawAsItsIdentity() throws {
        let folder = try TempFolder(); defer { folder.remove() }
        for name in ["IMG_1.ARW", "IMG_1.JPG", "IMG_2.arw", "IMG_2.jpeg", "IMG_3.ARW"] { try folder.add(name) }
        let photos = try FolderScanner.scan(folder.url).photos
        #expect(photos.count == 3)
        let pair = try #require(photos.first { $0.name == "IMG_1.ARW" })
        #expect(pair.companion?.url.lastPathComponent == "IMG_1.JPG")
        #expect(pair.shownURL.lastPathComponent == "IMG_1.JPG")
        #expect(!pair.showsRaw)
        #expect(photos.first { $0.name == "IMG_2.arw" }?.companion?.format == .jpeg)
        #expect(photos.first { $0.name == "IMG_3.ARW" }?.companion == nil)
        #expect(photos.first { $0.name == "IMG_3.ARW" }?.showsRaw == true)
    }

    @Test func caseDoesNotMatterForTheBaseName() throws {
        let folder = try TempFolder(); defer { folder.remove() }
        try folder.add("img_1.ARW"); try folder.add("IMG_1.jpg")
        #expect(try FolderScanner.scan(folder.url).photos.count == 1)
    }

    @Test func heicPairsToo() throws {
        let folder = try TempFolder(); defer { folder.remove() }
        try folder.add("a.DNG"); try folder.add("a.HEIC")
        let photos = try FolderScanner.scan(folder.url).photos
        #expect(photos.count == 1)
        #expect(photos[0].companion?.format == .heic)
    }

    @Test func aJpegPreferredOverHeicAndTheHeicStaysItsOwnFrame() throws {
        let folder = try TempFolder(); defer { folder.remove() }
        try folder.add("a.ARW"); try folder.add("a.jpg"); try folder.add("a.heic")
        let photos = try FolderScanner.scan(folder.url).photos
        #expect(photos.count == 2)
        #expect(photos.first { $0.format == .arw }?.companion?.format == .jpeg)
    }

    @Test func unclearCasesAreNotPaired() throws {
        let folder = try TempFolder(); defer { folder.remove() }
        // two RAWs with one base name; a TIFF beside a RAW; a JPEG alone; a JPEG beside a JPEG-less folder
        for name in ["a.ARW", "a.DNG", "a.jpg", "b.ARW", "b.tif", "c.jpg"] { try folder.add(name) }
        #expect(try FolderScanner.scan(folder.url).photos.count == 6)
    }

    @Test func pairingCanBeSwitchedOff() throws {
        let folder = try TempFolder(); defer { folder.remove() }
        try folder.add("a.ARW"); try folder.add("a.jpg")
        let photos = try FolderScanner.scan(folder.url, pairing: false).photos
        #expect(photos.count == 2)
        #expect(photos.allSatisfy { $0.companion == nil })
    }

    @Test func aPairListsBothFilesForReveal() throws {
        let folder = try TempFolder(); defer { folder.remove() }
        try folder.add("a.ARW"); try folder.add("a.jpg")
        let photo = try #require(try FolderScanner.scan(folder.url).photos.first)
        #expect(photo.files.map(\.lastPathComponent) == ["a.ARW", "a.jpg"])
    }
}

@Suite @MainActor struct RawJpegPairingModelTests {
    private func open(_ folder: TempFolder, naming: SidecarNaming = .stem, pairing: Bool = true) async -> FolderModel {
        let model = FolderModel()
        model.sidecarNaming = naming
        model.pairsRawAndJpeg = pairing
        model.open(folder.url)
        for _ in 0..<500 where model.content != .photos || model.isReadingSidecars || model.isReadingCaptureTimes {
            try? await Task.sleep(for: .milliseconds(10))
        }
        try? await Task.sleep(for: .milliseconds(50))
        return model
    }

    private func props(_ name: String, in folder: TempFolder) throws -> XMPProperties {
        try XMPReader.parse(Data(contentsOf: folder.url.appendingPathComponent(name)))
    }

    @Test func aRatingForAPairGoesToTheSharedSidecarOnly() async throws {
        let folder = try TempFolder(); defer { folder.remove() }
        try folder.add("a.ARW"); try folder.add("a.jpg")
        let model = await open(folder)
        #expect(model.photos.count == 1)
        model.apply(.setRating(4))
        model.flushSidecarWrites()
        #expect(try props("a.xmp", in: folder).rating == 4)
        #expect(!FileManager.default.fileExists(atPath: folder.url.appendingPathComponent("a.jpg.xmp").path))
    }

    @Test func withFullNameNamingBothFilesGetASidecar() async throws {
        let folder = try TempFolder(); defer { folder.remove() }
        try folder.add("a.ARW"); try folder.add("a.jpg")
        let model = await open(folder, naming: .fullName)
        model.apply(.setRating(2)); model.apply(.toggleLabel(.green))
        model.flushSidecarWrites()
        #expect(try props("a.ARW.xmp", in: folder) == XMPProperties(rating: 2, label: "Green"))
        #expect(try props("a.jpg.xmp", in: folder) == XMPProperties(rating: 2, label: "Green"))
    }

    @Test func undoToNothingRemovesBothSidecarsWeMade() async throws {
        let folder = try TempFolder(); defer { folder.remove() }
        try folder.add("a.ARW"); try folder.add("a.jpg")
        let model = await open(folder, naming: .fullName)
        model.apply(.setRating(5))
        model.flushSidecarWrites()
        model.undo()
        model.flushSidecarWrites()
        #expect(!FileManager.default.fileExists(atPath: folder.url.appendingPathComponent("a.ARW.xmp").path))
        #expect(!FileManager.default.fileExists(atPath: folder.url.appendingPathComponent("a.jpg.xmp").path))
    }

    @Test func revealSelectsBothFilesOfAPair() async throws {
        let folder = try TempFolder(); defer { folder.remove() }
        try folder.add("a.ARW"); try folder.add("a.jpg"); try folder.add("b.ARW")
        let model = await open(folder)
        model.selectAll()
        #expect(model.revealURLs.map(\.lastPathComponent).sorted() == ["a.ARW", "a.jpg", "b.ARW"])
    }

    @Test func switchedOffEveryFileIsAFrame() async throws {
        let folder = try TempFolder(); defer { folder.remove() }
        try folder.add("a.ARW"); try folder.add("a.jpg")
        #expect(await open(folder, pairing: false).photos.count == 2)
    }

    @Test func theJpegVanishingLeavesTheRawAlone() async throws {
        let folder = try TempFolder(); defer { folder.remove() }
        try folder.add("a.ARW"); let jpg = try folder.add("a.jpg")
        let model = await open(folder)
        try FileManager.default.removeItem(at: jpg)
        model.handleChanges(["a.jpg"])
        #expect(model.photos.count == 1)
        #expect(model.photos[0].companion == nil)
        #expect(model.newFileCount == 0)
    }
}
