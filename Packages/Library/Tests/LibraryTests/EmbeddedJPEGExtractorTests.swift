import Containers
import Darwin
import Foundation
import Synchronization
import Testing
@testable import Library

private func le16(_ v: UInt16) -> Data { Data([UInt8(v & 0xFF), UInt8(v >> 8)]) }
private func le32(_ v: UInt32) -> Data { Data([UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8(v >> 24)]) }

/// A small JPEG, with or without an Exif orientation.
private func jpeg(width: Int, height: Int, exifOrientation: UInt16? = nil) -> Data {
    var d = Data([0xFF, 0xD8])
    if let o = exifOrientation {
        let body = Data("Exif\0\0".utf8) + Data("MM".utf8) + Data([0, 42, 0, 0, 0, 8])
            + Data([0, 1, 0x01, 0x12, 0, 3, 0, 0, 0, 1, UInt8(o >> 8), UInt8(o & 0xFF), 0, 0, 0, 0, 0, 0])
        d += Data([0xFF, 0xE1, UInt8((body.count + 2) >> 8), UInt8((body.count + 2) & 0xFF)]) + body
    }
    d += Data([0xFF, 0xC0, 0, 11, 8, UInt8(height >> 8), UInt8(height & 0xFF), UInt8(width >> 8), UInt8(width & 0xFF), 1, 1, 0x11, 0])
    d += Data([0xFF, 0xDA, 0, 8, 1, 1, 0, 0, 63, 0, 0x12, 0x34, 0xFF, 0xD9])
    return d
}

/// A TIFF-based "RAW": IFD0 holds the orientation, IFD1 points at `preview`.
private func fakeRaw(orientation: UInt16, preview: Data) -> Data {
    var d = Data("II".utf8) + Data([42, 0, 8, 0, 0, 0])
    // IFD0 at 8: one entry (orientation), next-IFD = 8 + 2 + 12 + 4 = 26.
    d += le16(1) + le16(0x0112) + le16(3) + le32(1) + le16(orientation) + Data([0, 0]) + le32(26)
    // IFD1 at 26: two entries, then the blob at 26 + 2 + 24 + 4 = 56.
    d += le16(2) + le16(0x0201) + le16(4) + le32(1) + le32(56) + le16(0x0202) + le16(4) + le32(1) + le32(UInt32(preview.count)) + le32(0)
    d += preview
    return d
}

private func scratch() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("extract-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@Test func exactBytesCopiesTheEmbeddedStreamUnchanged() throws {
    let dir = try scratch(); defer { try? FileManager.default.removeItem(at: dir) }
    let preview = jpeg(width: 160, height: 120)
    let source = dir.appendingPathComponent("A.ARW")
    try fakeRaw(orientation: 6, preview: preview).write(to: source)
    let out = try scratch(); defer { try? FileManager.default.removeItem(at: out) }

    let result = try EmbeddedJPEGExtractor.extract(source, into: out, exactBytes: true)
    #expect(result.output.lastPathComponent == "A.jpg")
    #expect(!result.exifAdded)
    #expect(try Data(contentsOf: result.output) == preview)
}

@Test func defaultAddsOrientationAndKeepsTheImageData() throws {
    let dir = try scratch(); defer { try? FileManager.default.removeItem(at: dir) }
    let preview = jpeg(width: 160, height: 120)
    let source = dir.appendingPathComponent("A.ARW")
    try fakeRaw(orientation: 6, preview: preview).write(to: source)
    let out = try scratch(); defer { try? FileManager.default.removeItem(at: out) }

    let result = try EmbeddedJPEGExtractor.extract(source, into: out)
    #expect(result.exifAdded)
    let data = try Data(contentsOf: result.output)
    let header = try #require(JPEGHeader.parse(ByteReader(data: data), at: 0))
    #expect(header.exifOrientation == 6)
    #expect(data.suffix(preview.count - 2) == preview.suffix(preview.count - 2))
}

@Test func aPreviewsOwnOrientationWinsAndItsExifIsReplacedByTheRAWs() throws {
    let dir = try scratch(); defer { try? FileManager.default.removeItem(at: dir) }
    let preview = jpeg(width: 160, height: 120, exifOrientation: 8)
    let source = dir.appendingPathComponent("A.ARW")
    try fakeRaw(orientation: 6, preview: preview).write(to: source)
    let out = try scratch(); defer { try? FileManager.default.removeItem(at: out) }

    let result = try EmbeddedJPEGExtractor.extract(source, into: out)
    #expect(result.exifAdded)
    let data = try Data(contentsOf: result.output)
    #expect(try #require(JPEGHeader.parse(ByteReader(data: data), at: 0)).exifOrientation == 8)
    #expect(try #require(JPEGSegments.list(data)).filter(\.isExif).count == 1)
}

@Test func theFilesDatesPermissionsAndExtendedAttributesGoAlong() throws {
    let dir = try scratch(); defer { try? FileManager.default.removeItem(at: dir) }
    let source = dir.appendingPathComponent("A.ARW")
    try fakeRaw(orientation: 1, preview: jpeg(width: 160, height: 120)).write(to: source)
    let created = Date(timeIntervalSince1970: 1_500_000_000), modified = Date(timeIntervalSince1970: 1_600_000_000)
    try FileManager.default.setAttributes([.creationDate: created, .modificationDate: modified, .posixPermissions: 0o600],
                                          ofItemAtPath: source.path)
    let tag = Data("bplist-or-anything".utf8)
    #expect(tag.withUnsafeBytes { setxattr(source.path, "com.apple.metadata:test", $0.baseAddress, $0.count, 0, 0) } == 0)
    // setxattr and setAttributes can touch each other's times; set the dates again.
    try FileManager.default.setAttributes([.creationDate: created, .modificationDate: modified], ofItemAtPath: source.path)
    let out = try scratch(); defer { try? FileManager.default.removeItem(at: out) }

    for exact in [false, true] {
        let result = try EmbeddedJPEGExtractor.extract(source, into: out, exactBytes: exact)
        #expect(result.attributeWarnings.isEmpty)
        let a = try FileManager.default.attributesOfItem(atPath: result.output.path)
        #expect(a[.creationDate] as? Date == created)
        #expect(a[.modificationDate] as? Date == modified)
        #expect(a[.posixPermissions] as? Int == 0o600)
        var buffer = [UInt8](repeating: 0, count: 64)
        let n = getxattr(result.output.path, "com.apple.metadata:test", &buffer, 64, 0, 0)
        #expect(Data(buffer.prefix(max(n, 0))) == tag)
    }
}

@Test func theSidecarsRatingTravelsAsXMPUnlessExact() throws {
    let dir = try scratch(); defer { try? FileManager.default.removeItem(at: dir) }
    let source = dir.appendingPathComponent("A.ARW"), sidecar = dir.appendingPathComponent("A.xmp")
    try fakeRaw(orientation: 1, preview: jpeg(width: 160, height: 120)).write(to: source)
    let packet = "<x:xmpmeta xmlns:x=\"adobe:ns:meta/\"><rdf:RDF xmlns:rdf=\"http://www.w3.org/1999/02/22-rdf-syntax-ns#\"><rdf:Description xmlns:xmp=\"http://ns.adobe.com/xap/1.0/\" xmp:Rating=\"4\" xmp:Label=\"Green\"/></rdf:RDF></x:xmpmeta>"
    try Data(packet.utf8).write(to: sidecar)
    let out = try scratch(); defer { try? FileManager.default.removeItem(at: out) }

    let result = try EmbeddedJPEGExtractor.extract(source, into: out, sidecar: sidecar)
    #expect(result.xmpAdded)
    let data = try Data(contentsOf: result.output)
    let segment = try #require(JPEGSegments.list(data)?.first { $0.isXMP })
    #expect(String(decoding: data[segment.range], as: UTF8.self).contains("xmp:Rating=\"4\""))

    let exact = try EmbeddedJPEGExtractor.extract(source, into: out, exactBytes: true, sidecar: sidecar)
    #expect(!exact.xmpAdded)
    #expect(try #require(JPEGSegments.list(Data(contentsOf: exact.output))).allSatisfy { !$0.isXMP })
}

@Test func takenNamesGetASuffixAndNothingIsOverwritten() throws {
    let dir = try scratch(); defer { try? FileManager.default.removeItem(at: dir) }
    let a = dir.appendingPathComponent("IMG_1.ARW"), b = dir.appendingPathComponent("IMG_1.NEF")
    try fakeRaw(orientation: 1, preview: jpeg(width: 160, height: 120)).write(to: a)
    try fakeRaw(orientation: 1, preview: jpeg(width: 320, height: 240)).write(to: b)
    let out = try scratch(); defer { try? FileManager.default.removeItem(at: out) }
    let existing = out.appendingPathComponent("IMG_1.jpg")
    try Data("mine".utf8).write(to: existing)

    let summary = EmbeddedJPEGExtractor.run([a, b], into: out, exactBytes: true)
    #expect(summary.written == 2)
    #expect(summary.renamed.map(\.detail) == ["IMG_1-1.jpg", "IMG_1-2.jpg"])
    #expect(try Data(contentsOf: existing) == Data("mine".utf8))
}

@Test func summaryListsFilesWithoutAJPEGAndNonRawOriginals() throws {
    let dir = try scratch(); defer { try? FileManager.default.removeItem(at: dir) }
    let none = dir.appendingPathComponent("B.ARW"), camera = dir.appendingPathComponent("C.JPG"), missing = dir.appendingPathComponent("D.ARW")
    try Data("not an image".utf8).write(to: none)
    try jpeg(width: 10, height: 10).write(to: camera)
    let out = try scratch(); defer { try? FileManager.default.removeItem(at: out) }

    let summary = EmbeddedJPEGExtractor.run([none, camera, missing], into: out)
    #expect(summary.written == 0)
    #expect(summary.withoutEmbeddedJPEG == ["B.ARW"])
    #expect(summary.notRaw == ["C.JPG"])
    #expect(summary.failed.map(\.name) == ["D.ARW"])
    #expect(summary.hasProblems)
    #expect(try FileManager.default.contentsOfDirectory(atPath: out.path).isEmpty)
}

@Test func cancelStopsBetweenFilesAndLeavesNoTemporaryFile() throws {
    let dir = try scratch(); defer { try? FileManager.default.removeItem(at: dir) }
    var sources: [URL] = []
    for i in 0..<5 {
        let url = dir.appendingPathComponent("F\(i).ARW")
        try fakeRaw(orientation: 1, preview: jpeg(width: 160, height: 120)).write(to: url)
        sources.append(url)
    }
    let out = try scratch(); defer { try? FileManager.default.removeItem(at: out) }
    let done = Mutex(0)
    let summary = EmbeddedJPEGExtractor.run(sources, into: out, exactBytes: true, parallelism: 1,
                                            progress: { n in done.withLock { $0 = n } }, isCancelled: { done.withLock { $0 >= 2 } })
    #expect(summary.cancelled)
    #expect(summary.written == 2)
    #expect(try FileManager.default.contentsOfDirectory(atPath: out.path).sorted() == ["F0.jpg", "F1.jpg"])
}

@Test func parallelRunGivesTheSameNamesAsASerialOne() throws {
    let dir = try scratch(); defer { try? FileManager.default.removeItem(at: dir) }
    var sources: [URL] = []
    for i in 0..<40 {
        for ext in ["ARW", "NEF"] where i % 4 == 0 || ext == "ARW" {
            let url = dir.appendingPathComponent("IMG_\(i).\(ext)")
            try fakeRaw(orientation: 1, preview: jpeg(width: 160 + i, height: 120)).write(to: url)
            sources.append(url)
        }
    }
    let out = try scratch(); defer { try? FileManager.default.removeItem(at: out) }
    let summary = EmbeddedJPEGExtractor.run(sources, into: out, exactBytes: true, parallelism: 8)
    #expect(summary.written == sources.count && !summary.cancelled)
    #expect(summary.renamed.count == 10 && summary.renamed.allSatisfy { $0.name.hasSuffix(".NEF") && $0.detail.hasSuffix("-1.jpg") })
    #expect(try FileManager.default.contentsOfDirectory(atPath: out.path).count == sources.count)
}

// MARK: V-22

@Test func theSwitchRemovesTheSidecarsLocationButKeepsRatingAndLabel() throws {
    let dir = try scratch(); defer { try? FileManager.default.removeItem(at: dir) }
    let source = dir.appendingPathComponent("A.ARW"), sidecar = dir.appendingPathComponent("A.xmp")
    try fakeRaw(orientation: 1, preview: jpeg(width: 160, height: 120)).write(to: source)
    let packet = "<x:xmpmeta xmlns:x=\"adobe:ns:meta/\"><rdf:RDF xmlns:rdf=\"http://www.w3.org/1999/02/22-rdf-syntax-ns#\"><rdf:Description xmlns:xmp=\"http://ns.adobe.com/xap/1.0/\" xmlns:exif=\"http://ns.adobe.com/exif/1.0/\" xmlns:aux=\"http://ns.adobe.com/exif/1.0/aux/\" xmp:Rating=\"4\" xmp:Label=\"Green\" exif:GPSLatitude=\"47,49.3N\" aux:SerialNumber=\"BODY999\"/></rdf:RDF></x:xmpmeta>"
    try Data(packet.utf8).write(to: sidecar)
    let out = try scratch(); defer { try? FileManager.default.removeItem(at: out) }

    let result = try EmbeddedJPEGExtractor.extract(source, into: out, sidecar: sidecar, removePrivate: true)
    #expect(result.xmpAdded && !result.xmpSkipped)
    let data = try Data(contentsOf: result.output)
    let segment = try #require(JPEGSegments.list(data)?.first { $0.isXMP })
    let text = String(decoding: data[segment.range], as: UTF8.self)
    #expect(text.contains("Rating") && text.contains("Green"))
    #expect(!text.contains("47,49") && !text.contains("BODY999") && !text.contains("GPSLatitude"))
}

@Test func anUnreadableSidecarIsLeftOutWhenTheSwitchIsOn() throws {
    let dir = try scratch(); defer { try? FileManager.default.removeItem(at: dir) }
    let source = dir.appendingPathComponent("A.ARW"), sidecar = dir.appendingPathComponent("A.xmp")
    try fakeRaw(orientation: 1, preview: jpeg(width: 160, height: 120)).write(to: source)
    try Data("this is not xmp, 47.8N".utf8).write(to: sidecar)
    let out = try scratch(); defer { try? FileManager.default.removeItem(at: out) }

    let result = try EmbeddedJPEGExtractor.extract(source, into: out, sidecar: sidecar, removePrivate: true)
    #expect(result.xmpSkipped && !result.xmpAdded)
    #expect(try #require(JPEGSegments.list(Data(contentsOf: result.output))).allSatisfy { !$0.isXMP })
}

@Test func exactBytesWithTheSwitchKeepsTheImageButDropsThePreviewsOwnXMPAndIPTC() throws {
    let dir = try scratch(); defer { try? FileManager.default.removeItem(at: dir) }
    let plain = jpeg(width: 160, height: 120)
    let xmp = try #require(JPEGSegments.xmpSegment(Data("<x:xmpmeta>Munich</x:xmpmeta>".utf8)))
    let iptc = Data([0xFF, 0xED, 0, 11]) + Data("Photoshop".utf8)
    let preview = plain.prefix(2) + xmp + iptc + plain.dropFirst(2)
    let source = dir.appendingPathComponent("A.ARW")
    try fakeRaw(orientation: 1, preview: Data(preview)).write(to: source)
    let out = try scratch(); defer { try? FileManager.default.removeItem(at: out) }

    let kept = try EmbeddedJPEGExtractor.extract(source, into: out, exactBytes: true)
    #expect(try Data(contentsOf: kept.output) == Data(preview))     // as before: unchanged
    let result = try EmbeddedJPEGExtractor.extract(source, into: out, exactBytes: true, removePrivate: true)
    let data = try Data(contentsOf: result.output)
    #expect(data.range(of: Data("Munich".utf8)) == nil)
    #expect(try #require(JPEGSegments.list(data)).allSatisfy { !$0.isXMP && $0.marker != 0xED })
    #expect(data.suffix(14) == plain.suffix(14))                     // the scan data is the same
}

@Test func theRunnerRemembersThatThePrivateFieldsWereRemoved() throws {
    let dir = try scratch(); defer { try? FileManager.default.removeItem(at: dir) }
    let source = dir.appendingPathComponent("A.ARW")
    try fakeRaw(orientation: 1, preview: jpeg(width: 160, height: 120)).write(to: source)
    let out = try scratch(); defer { try? FileManager.default.removeItem(at: out) }
    #expect(EmbeddedJPEGExtractor.run([source], into: out, removePrivate: true).removedPrivate)
    #expect(!EmbeddedJPEGExtractor.run([source], into: out).removedPrivate)
}

