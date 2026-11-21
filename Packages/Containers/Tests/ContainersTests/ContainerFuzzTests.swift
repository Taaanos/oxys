import Foundation
import Testing
@testable import Containers

// MARK: - Deterministic PRNG (SplitMix64)

private struct SeededRNG {
    private var state: UInt64

    init(seed: UInt64) { self.state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    mutating func int(in range: ClosedRange<Int>) -> Int {
        let span = UInt64(range.upperBound - range.lowerBound) + 1
        return range.lowerBound + Int(next() % span)
    }

    mutating func bool(probability num: Int = 1, outOf den: Int = 2) -> Bool {
        Int(next() % UInt64(den)) < num
    }

    mutating func pick<T>(_ items: [T]) -> T {
        items[Int(next() % UInt64(items.count))]
    }
}

private func hex(_ seed: UInt64) -> String { "0x" + String(seed, radix: 16, uppercase: true) }

// MARK: - Synthetic Container Builders

private func be16(_ v: Int) -> Data { Data([UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)]) }
private func be32(_ v: Int) -> Data {
    Data([UInt8((v >> 24) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)])
}
private func le16(_ v: Int) -> Data { Data([UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF)]) }
private func le32(_ v: Int) -> Data {
    Data([UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 24) & 0xFF)])
}

private func buildSyntheticJPEG(width: Int, height: Int, orientation: ExifOrientation?, withICC: Bool, withXMP: Bool) -> Data {
    var d = Data([0xFF, 0xD8])
    if let orientation,
       let exif = ExifSegment.build(ExifSegment.Fields(make: "TestCam", model: "M1", orientation: orientation,
                                                       dateTimeOriginal: "2026:10:01 12:34:56")) {
        d += exif
    }
    if withXMP, let xmp = JPEGSegments.xmpSegment(Data("<x:xmpmeta xmlns:x=\"adobe:ns:meta/\"/>".utf8)) {
        d += xmp
    }
    if withICC, let icc = JPEGSegments.iccSegment(Data(repeating: 0x42, count: 64)) {
        d += icc
    }
    // SOF0
    d += Data([0xFF, 0xC0, 0x00, 0x0B, 0x08])
    d += be16(height) + be16(width)
    d += Data([0x01, 0x01, 0x11, 0x00])
    // SOS + tiny entropy stream + EOI
    d += Data([0xFF, 0xDA, 0x00, 0x08, 0x01, 0x01, 0x00, 0x00, 0x3F, 0x00, 0xAB, 0xCD, 0xFF, 0xD9])
    return d
}

private func buildSyntheticTIFF(rng: inout SeededRNG) -> (data: Data, expectedOffset: Int, expectedLength: Int, width: Int, height: Int) {
    let bigEndian = rng.bool()
    func u16(_ v: Int) -> Data { bigEndian ? be16(v) : le16(v) }
    func u32(_ v: Int) -> Data { bigEndian ? be32(v) : le32(v) }

    let width = rng.int(in: 160...4000)
    let height = rng.int(in: 120...3000)
    let orient = rng.pick(ExifOrientation.allCases)
    let jpeg = buildSyntheticJPEG(width: width, height: height, orientation: orient, withICC: rng.bool(), withXMP: rng.bool())

    // Header (8 bytes) + IFD0 (2 + 1*12 + 4 = 18 bytes) + JPEG blob + IFD1 (2 + 2*12 + 4 = 30 bytes)
    var d = Data((bigEndian ? "MM" : "II").utf8) + u16(42) + u32(8)
    let blobOffset = 8 + 18
    let ifd1Offset = blobOffset + jpeg.count

    // IFD0: Orientation tag, next -> IFD1
    d += u16(1)
    d += u16(0x0112) + u16(3) + u32(1) + u16(Int(orient.rawValue)) + Data([0, 0])
    d += u32(ifd1Offset)

    d += jpeg

    // IFD1: JPEGInterchangeFormat (0x0201) + JPEGInterchangeFormatLength (0x0202)
    d += u16(2)
    d += u16(0x0201) + u16(4) + u32(1) + u32(blobOffset)
    d += u16(0x0202) + u16(4) + u32(1) + u32(jpeg.count)
    d += u32(0)

    return (d, blobOffset, jpeg.count, width, height)
}

private func buildSyntheticRAF(rng: inout SeededRNG) -> (data: Data, expectedOffset: Int, expectedLength: Int, width: Int, height: Int) {
    let width = rng.int(in: 320...3000)
    let height = rng.int(in: 240...2000)
    let jpeg = buildSyntheticJPEG(width: width, height: height, orientation: .up, withICC: false, withXMP: false)

    // Fujifilm RAF header: 16-byte magic + padding to offset 84 (JPEG offset, BE u32) and 88 (JPEG length, BE u32)
    let jpegOffset = 160
    var d = Data("FUJIFILMCCD-RAW ".utf8)
    d += Data(repeating: 0x20, count: 84 - d.count)
    d += be32(jpegOffset)
    d += be32(jpeg.count)
    d += Data(repeating: 0x00, count: jpegOffset - d.count)
    d += jpeg
    return (d, jpegOffset, jpeg.count, width, height)
}

private func box(_ type: String, payload: Data) -> Data {
    be32(8 + payload.count) + Data(type.utf8) + payload
}

private func buildSyntheticCR3(rng: inout SeededRNG) -> (data: Data, expectedOffset: Int, expectedLength: Int, width: Int, height: Int) {
    let width = rng.int(in: 320...4000)
    let height = rng.int(in: 240...3000)
    let jpeg = buildSyntheticJPEG(width: width, height: height, orientation: .up, withICC: rng.bool(), withXMP: false)

    let ftyp = box("ftyp", payload: Data("crx ".utf8) + be32(0) + Data("crx isom".utf8))
    // PRVW box: 4 bytes version/flags + 2 bytes pad + 2 bytes w + 2 bytes h + 2 bytes pad + 4 bytes jpegLen + jpeg
    let prvwPayload = Data(repeating: 0, count: 6) + be16(width) + be16(height) + Data([0, 0]) + be32(jpeg.count) + jpeg
    let prvw = box("PRVW", payload: prvwPayload)
    // Canon PRVW UUID (eaf42b5e-1c98-4b88-b9fb-b7dc406e4d16)
    let prvwUUID = Data([0xEA, 0xF4, 0x2B, 0x5E, 0x1C, 0x98, 0x4B, 0x88, 0xB9, 0xFB, 0xB7, 0xDC, 0x40, 0x6E, 0x4D, 0x16])
    let uuid = box("uuid", payload: prvwUUID + Data(repeating: 0, count: 8) + prvw)

    let data = ftyp + uuid
    let jpegOffset = data.count - jpeg.count
    return (data, jpegOffset, jpeg.count, width, height)
}

// MARK: - Suite: Container Fuzzing & Round-Trip Invariants

@Suite struct ContainerFuzzTests {
    @Test(arguments: [UInt64(0xE001), 0xE002, 0xE003, 0xE004])
    func syntheticContainersAndJPEGRewritingRoundTrip(seed: UInt64) throws {
        var rng = SeededRNG(seed: seed)

        for i in 0..<40 {
            // 1. TIFF preview locator round-trip
            let tiff = buildSyntheticTIFF(rng: &rng)
            let locatedTIFF = try #require(PreviewLocator.locate(in: tiff.data),
                                           "seed=\(hex(seed)) iter=\(i): failed to locate TIFF preview")
            let p1 = try #require(locatedTIFF.largest)
            #expect(p1.offset == tiff.expectedOffset && p1.length == tiff.expectedLength,
                    "seed=\(hex(seed)) iter=\(i): TIFF preview span mismatch")
            #expect(p1.width == tiff.width && p1.height == tiff.height)

            // 2. RAF preview locator round-trip
            let raf = buildSyntheticRAF(rng: &rng)
            let locatedRAF = try #require(PreviewLocator.locate(in: raf.data),
                                          "seed=\(hex(seed)) iter=\(i): failed to locate RAF preview")
            let p2 = try #require(locatedRAF.largest)
            #expect(p2.offset == raf.expectedOffset && p2.length == raf.expectedLength,
                    "seed=\(hex(seed)) iter=\(i): RAF preview span mismatch")
            #expect(p2.width == raf.width && p2.height == raf.height)

            // 3. CR3 preview locator round-trip
            let cr3 = buildSyntheticCR3(rng: &rng)
            let locatedCR3 = try #require(PreviewLocator.locate(in: cr3.data),
                                          "seed=\(hex(seed)) iter=\(i): failed to locate CR3 preview")
            let p3 = try #require(locatedCR3.largest)
            #expect(p3.offset == cr3.expectedOffset && p3.length == cr3.expectedLength,
                    "seed=\(hex(seed)) iter=\(i): CR3 preview span mismatch")
            #expect(p3.width == cr3.width && p3.height == cr3.height)

            // 4. JPEGSegments.rewriting preserves SOS+entropy bytes & parses back cleanly
            let orient = rng.pick(ExifOrientation.allCases)
            let origJPEG = buildSyntheticJPEG(width: 640, height: 480, orientation: orient,
                                              withICC: rng.bool(), withXMP: rng.bool())
            let newOrient = rng.pick(ExifOrientation.allCases)
            let newExif = ExifSegment.build(ExifSegment.Fields(make: "Fuji", model: "X-T5", orientation: newOrient))
            let newXMP = rng.bool() ? JPEGSegments.xmpSegment(Data("<x:xmpmeta xmlns:x=\"adobe:ns:meta/\"/>".utf8)) : nil
            let rewritten = try #require(JPEGSegments.rewriting(origJPEG, exif: newExif, xmp: newXMP,
                                                                droppingXMPAndIPTC: rng.bool()),
                                         "seed=\(hex(seed)) iter=\(i): JPEGSegments.rewriting returned nil")
            let header = try #require(JPEGHeader.parse(ByteReader(data: rewritten), at: 0))
            #expect(header.width == 640 && header.height == 480)
            #expect(header.exifOrientation == newOrient,
                    "seed=\(hex(seed)) iter=\(i): rewritten EXIF orientation mismatch")
            let segments = try #require(JPEGSegments.list(rewritten))
            for seg in segments {
                #expect(seg.range.lowerBound >= 2 && seg.range.upperBound <= rewritten.count)
            }
        }
    }

    @Test(arguments: [UInt64(0x5A01), 0x5A02, 0x5A03, 0x5A04, 0x5A05, 0x5A06])
    func mutatedContainersNeverTrapAndAlwaysRespectBounds(seed: UInt64) {
        var rng = SeededRNG(seed: seed)

        for i in 0..<300 {
            var bytes: [UInt8]
            switch rng.int(in: 0...4) {
            case 0: bytes = [UInt8](buildSyntheticTIFF(rng: &rng).data)
            case 1: bytes = [UInt8](buildSyntheticRAF(rng: &rng).data)
            case 2: bytes = [UInt8](buildSyntheticCR3(rng: &rng).data)
            case 3: bytes = [UInt8](buildSyntheticJPEG(width: 320, height: 240, orientation: .up, withICC: true, withXMP: true))
            default:
                let len = rng.int(in: 0...256)
                bytes = (0..<len).map { _ in UInt8(rng.int(in: 0...255)) }
            }

            // Apply 1..3 structural mutations
            let mutationCount = rng.int(in: 1...3)
            for _ in 0..<mutationCount where !bytes.isEmpty {
                switch rng.int(in: 0...5) {
                case 0: // Truncate
                    let cut = rng.int(in: 0...(bytes.count - 1))
                    bytes = Array(bytes.prefix(cut))
                case 1: // Random byte overwrite
                    for _ in 0..<rng.int(in: 1...12) {
                        let pos = rng.int(in: 0...(bytes.count - 1))
                        bytes[pos] = UInt8(rng.int(in: 0...255))
                    }
                case 2: // Write adversarial 16-bit / 32-bit values (0, 1, 0xFFFF, 0x7FFFFFFF, 0xFFFFFFFF)
                    let pos = rng.int(in: 0...max(0, bytes.count - 4))
                    let poison: [UInt8] = rng.pick([[0, 0, 0, 0], [0, 0, 0, 1], [0xFF, 0xFF, 0xFF, 0xFF],
                                                    [0x7F, 0xFF, 0xFF, 0xFF], [0xFF, 0xFF, 0x00, 0x00]])
                    for (k, b) in poison.enumerated() where pos + k < bytes.count { bytes[pos + k] = b }
                case 3: // Duplicate a slice (can create nested/looping boxes or extra markers)
                    let start = rng.int(in: 0...(bytes.count - 1))
                    let end = min(bytes.count, start + rng.int(in: 1...32))
                    if bytes.count < 4096 { bytes.append(contentsOf: bytes[start..<end]) }
                case 4: // Inject 0xFF marker bytes
                    let pos = rng.int(in: 0...(bytes.count - 1))
                    bytes[pos] = 0xFF
                    if pos + 1 < bytes.count { bytes[pos + 1] = rng.pick([0x00, 0xD8, 0xD9, 0xDA, 0xE1, 0xE2, 0xC0, 0xFF]) }
                default: // Drop a middle chunk
                    let start = rng.int(in: 0...(bytes.count - 1))
                    let len = min(bytes.count - start, rng.int(in: 1...24))
                    bytes.removeSubrange(start..<(start + len))
                }
            }

            let data = Data(bytes)

            // 1. PreviewLocator must never crash/hang, and every returned preview must lie strictly in-bounds.
            if let located = PreviewLocator.locate(in: data) {
                for p in located.previews {
                    #expect(p.offset >= 0 && p.length > 0 && p.offset + p.length <= data.count,
                            "seed=\(hex(seed)) case=\(i): out-of-bounds preview \(p.offset)..<\(p.offset + p.length) in \(data.count) bytes")
                    #expect(p.width > 0 && p.height > 0,
                            "seed=\(hex(seed)) case=\(i): non-positive dimensions \(p.width)x\(p.height)")
                    let slice = PreviewLocator.bytes(of: p, in: data)
                    #expect(slice.count == p.length && slice.prefix(2) == Data([0xFF, 0xD8]),
                            "seed=\(hex(seed)) case=\(i): located preview does not start with SOI")
                }
            }

            // 2. JPEGHeader must never crash/hang; any parsed header has positive dimensions and components.
            if let header = JPEGHeader.parse(ByteReader(data: data), at: 0) {
                #expect(header.width > 0 && header.height > 0 && header.componentCount > 0,
                        "seed=\(hex(seed)) case=\(i): invalid JPEGHeader \(header.width)x\(header.height) c=\(header.componentCount)")
            }

            // 3. JPEGSegments.list must never crash/hang; segments must be in-bounds and non-overlapping.
            if let segments = JPEGSegments.list(data) {
                var prevEnd = 2
                for seg in segments {
                    #expect(seg.range.lowerBound >= prevEnd && seg.range.upperBound <= data.count,
                            "seed=\(hex(seed)) case=\(i): overlapping or out-of-bounds segment \(seg.range) in \(data.count)")
                    prevEnd = seg.range.upperBound
                }
            }
        }
    }

    /// Regression test from `mutatedContainersNeverTrapAndAlwaysRespectBounds` (seeds 0x5A03/0x5A04/0x5A05):
    /// `JPEGHeader.parse` must reject zero-dimension, zero-component, or truncated SOF frames.
    @Test func rejectsZeroOrTruncatedSOFDimensions() {
        // SOI + SOF0 with height=0, width=372 (reproduced from seed=0x5A03 case=202)
        let zeroHeight = Data([0xFF, 0xD8, 0xFF, 0xC0, 0x00, 0x0B, 0x08, 0x00, 0x00, 0x01, 0x74, 0x01, 0x01, 0x11, 0x00])
        // SOI + SOF0 with height=2538, width=0 (reproduced from seed=0x5A04 case=220)
        let zeroWidth = Data([0xFF, 0xD8, 0xFF, 0xC0, 0x00, 0x0B, 0x08, 0x09, 0xEA, 0x00, 0x00, 0x01, 0x01, 0x11, 0x00])
        // SOI + SOF0 with componentCount=0
        let zeroComponents = Data([0xFF, 0xD8, 0xFF, 0xC0, 0x00, 0x0B, 0x08, 0x01, 0x00, 0x01, 0x00, 0x00, 0x01, 0x11, 0x00])
        // SOI + truncated SOF0 header cut off before width/height bytes
        let truncatedSOF = Data([0xFF, 0xD8, 0xFF, 0xC0, 0x00, 0x0B, 0x08])
        // SOI + SOF0 with declared length < 8
        let shortLengthSOF = Data([0xFF, 0xD8, 0xFF, 0xC0, 0x00, 0x05, 0x08, 0x01, 0x00, 0x01, 0x00, 0x01])

        #expect(JPEGHeader.parse(ByteReader(data: zeroHeight), at: 0) == nil)
        #expect(JPEGHeader.parse(ByteReader(data: zeroWidth), at: 0) == nil)
        #expect(JPEGHeader.parse(ByteReader(data: zeroComponents), at: 0) == nil)
        #expect(JPEGHeader.parse(ByteReader(data: truncatedSOF), at: 0) == nil)
        #expect(JPEGHeader.parse(ByteReader(data: shortLengthSOF), at: 0) == nil)
    }
}
