import Containers
import Foundation
import Testing
@testable import Metadata

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

    mutating func double01() -> Double {
        Double(next() & 0x001F_FFFF_FFFF_FFFF) / Double(0x0020_0000_0000_0000)
    }

    mutating func bool(probability num: Int = 1, outOf den: Int = 2) -> Bool {
        Int(next() % UInt64(den)) < num
    }

    mutating func pick<T>(_ items: [T]) -> T {
        items[Int(next() % UInt64(items.count))]
    }
}

private func hex(_ seed: UInt64) -> String { "0x" + String(seed, radix: 16, uppercase: true) }

// MARK: - Synthetic MakerNote / EXIF Builder

private func buildRandomBrandTIFF(rng: inout SeededRNG) -> Data {
    let fixture = TIFFFixture(bigEndian: rng.bool())
    let make = rng.pick(["SONY", "Canon", "NIKON CORPORATION", "FUJIFILM", "Leica Camera AG"])
    let orient = rng.int(in: 1...8)
    let dateStr = String(format: "2026:%02d:%02d %02d:%02d:%02d",
                         rng.int(in: 1...12), rng.int(in: 1...28),
                         rng.int(in: 0...23), rng.int(in: 0...59), rng.int(in: 0...59))

    let exif: [TIFFFixture.Entry] = [
        fixture.ascii(0x9003, dateStr),
        fixture.ascii(0xA434, "FE 35mm F1.4 GM"),
        fixture.rationals(0x920A, [(rng.int(in: 14...600), max(1, rng.int(in: 1...10)))]),
    ]

    let afX = rng.int(in: 0...6000)
    let afY = rng.int(in: 0...4000)
    let afMode = rng.int(in: 0...10)

    return fixture.file(make: make, orientation: orient, exif: exif) { position in
        switch make {
        case "SONY":
            // Sony maker note IFD with focus location (0x2027) and lens spec
            let entries = [
                fixture.shorts(0x2027, [6000, 4000, afX, afY]),
                fixture.shorts(0xB029, [afMode]),
            ]
            return fixture.ifd(entries, origin: position, base: 0).bytes
        case "Canon":
            let entries = [
                fixture.ascii(0x0095, "RF50mm F1.2 L USM"),
                fixture.shorts(0x0038, [1, 1, 6000, 4000, 200, 200, 100, -100, 1], signed: true),
            ]
            return fixture.ifd(entries, origin: position, base: 0).bytes
        case "NIKON CORPORATION":
            // Nikon Type 3 maker note has 10-byte "Nikon\0\2\x10\0\0" prefix followed by an embedded TIFF header.
            let sub = TIFFFixture(bigEndian: fixture.bigEndian)
            let inner = sub.header + sub.ifd([
                sub.rationals(0x0084, [(24, 1), (70, 1), (28, 10), (28, 10)]),
            ], origin: 8, base: 0).bytes
            return Array("Nikon\0".utf8) + [2, 0x10, 0, 0] + inner
        case "FUJIFILM":
            // Fujifilm maker note: "FUJIFILM" + LE u32(12) + IFD relative to maker note start.
            let sub = TIFFFixture(bigEndian: false)
            let inner = sub.ifd([
                sub.shorts(0x1023, [afX, afY]),
            ], origin: 12, base: 0).bytes
            return Array("FUJIFILM".utf8) + sub.u32(12) + inner
        default:
            return fixture.ifd([fixture.shorts(0x0001, [1, 2, 3])], origin: position, base: 0).bytes
        }
    }
}

// MARK: - Suite: Metadata Fuzzing & Property Tests

@Suite struct MetadataFuzzTests {
    @Test(arguments: [UInt64(0x7001), 0x7002, 0x7003, 0x7004, 0x7005, 0x7006])
    func mutatedMetadataNeverTrapsAndPreservesInvariants(seed: UInt64) {
        var rng = SeededRNG(seed: seed)

        for i in 0..<300 {
            var bytes: [UInt8]
            if rng.bool(probability: 4, outOf: 5) {
                bytes = [UInt8](buildRandomBrandTIFF(rng: &rng))
            } else {
                let len = rng.int(in: 0...256)
                bytes = (0..<len).map { _ in UInt8(rng.int(in: 0...255)) }
            }

            // Apply 1..3 structural mutations (including zero denominators, cyclic IFDs, huge counts, truncation).
            for _ in 0..<rng.int(in: 1...3) where !bytes.isEmpty {
                switch rng.int(in: 0...4) {
                case 0:
                    let cut = rng.int(in: 0...(bytes.count - 1))
                    bytes = Array(bytes.prefix(cut))
                case 1:
                    for _ in 0..<rng.int(in: 1...10) {
                        bytes[rng.int(in: 0...(bytes.count - 1))] = UInt8(rng.int(in: 0...255))
                    }
                case 2:
                    let pos = rng.int(in: 0...max(0, bytes.count - 4))
                    let poison: [UInt8] = rng.pick([[0, 0, 0, 0], [0xFF, 0xFF, 0xFF, 0xFF],
                                                    [0x7F, 0xFF, 0xFF, 0xFF], [8, 0, 0, 0], [0, 0, 0, 8]])
                    for (k, b) in poison.enumerated() where pos + k < bytes.count { bytes[pos + k] = b }
                case 3:
                    // Zero out a rational denominator or count region
                    let start = rng.int(in: 0...(bytes.count - 1))
                    let len = min(bytes.count - start, rng.int(in: 2...8))
                    for k in start..<(start + len) { bytes[k] = 0 }
                default:
                    let start = rng.int(in: 0...(bytes.count - 1))
                    let len = min(bytes.count - start, rng.int(in: 1...16))
                    bytes.removeSubrange(start..<(start + len))
                }
            }

            let data = Data(bytes)

            // 1. MakerNoteReader: never traps/loops; any decoded AF points must have finite coordinates.
            if let note = MakerNoteReader.read(from: data), let af = note.af {
                #expect(!af.points.isEmpty, "seed=\(hex(seed)) case=\(i): AFDetection had empty points")
                for pt in af.points {
                    #expect(pt.x.isFinite && pt.y.isFinite,
                            "seed=\(hex(seed)) case=\(i): non-finite AFPoint (\(pt.x), \(pt.y))")
                    if let area = pt.area {
                        #expect(area.width.isFinite && area.height.isFinite,
                                "seed=\(hex(seed)) case=\(i): non-finite AFAreaSize")
                    }
                }
            }

            // 2. ExifTransplant from RAW: never traps; any emitted APP1 segment has valid framing.
            let orient = rng.pick(ExifOrientation.allCases)
            if let transplanted = ExifTransplant.segment(fromRAW: data, previewWidth: 1600, previewHeight: 1200,
                                                         orientation: orient, removePrivate: rng.bool()) {
                let seg = transplanted.segment
                #expect(seg.count >= 10 && seg[seg.startIndex] == 0xFF && seg[seg.startIndex + 1] == 0xE1,
                        "seed=\(hex(seed)) case=\(i): invalid APP1 prefix")
                let declaredLen = (Int(seg[seg.startIndex + 2]) << 8) | Int(seg[seg.startIndex + 3])
                #expect(declaredLen == seg.count - 2,
                        "seed=\(hex(seed)) case=\(i): APP1 length field \(declaredLen) != \(seg.count - 2)")
            }

            // 3. ExifTransplant from APP1 Exif segment wrapper: never traps.
            let app1 = Data([0xFF, 0xE1, UInt8(((data.count + 8) >> 8) & 0xFF), UInt8((data.count + 8) & 0xFF)])
                + Data("Exif\0\0".utf8) + data
            _ = ExifTransplant.segment(fromExifSegment: app1, previewWidth: 1600, previewHeight: 1200, orientation: orient)

            // 4. CaptureTime string extraction: never traps.
            _ = CaptureTime.dateTimeOriginalString(in: data)
        }
    }

    @Test(arguments: [UInt64(0x8001), 0x8002, 0x8003, 0x8004])
    func afPointUprightGroupAndBoundsProperties(seed: UInt64) {
        var rng = SeededRNG(seed: seed)
        let eps = 1e-12

        for step in 0..<200 {
            let x = rng.double01()
            let y = rng.double01()
            let w = rng.double01() * 0.25
            let h = rng.double01() * 0.25
            let pt = AFPoint(x: x, y: y, area: AFAreaSize(width: w, height: h))

            // Every orientation keeps coordinates inside [0, 1] and preserves area dimensions (possibly swapped).
            for o in ExifOrientation.allCases {
                let u = pt.upright(orientation: o)
                #expect(u.x >= -eps && u.x <= 1 + eps && u.y >= -eps && u.y <= 1 + eps,
                        "seed=\(hex(seed)) step=\(step) orient=\(o): out of [0,1]")
                if o.swapsAxes {
                    #expect(u.area?.width == h && u.area?.height == w)
                } else {
                    #expect(u.area?.width == w && u.area?.height == h)
                }
            }

            // 4x 90-degree rotations (.right) return to identity.
            let rot4 = pt.upright(orientation: .right).upright(orientation: .right)
                .upright(orientation: .right).upright(orientation: .right)
            #expect(abs(rot4.x - x) < eps && abs(rot4.y - y) < eps,
                    "seed=\(hex(seed)) step=\(step): 4x .right != identity")

            // .right followed by .left is identity.
            let rl = pt.upright(orientation: .right).upright(orientation: .left)
            #expect(abs(rl.x - x) < eps && abs(rl.y - y) < eps,
                    "seed=\(hex(seed)) step=\(step): .right + .left != identity")

            // Involutions: .up, .upMirrored, .down, .downMirrored, .leftMirrored, .rightMirrored are self-inverse.
            for inv in [ExifOrientation.up, .upMirrored, .down, .downMirrored, .leftMirrored, .rightMirrored] {
                let twice = pt.upright(orientation: inv).upright(orientation: inv)
                #expect(abs(twice.x - x) < eps && abs(twice.y - y) < eps,
                        "seed=\(hex(seed)) step=\(step): \(inv) not self-inverse")
            }
        }
    }

    @Test(arguments: [UInt64(0x9001), 0x9002, 0x9003, 0x9004])
    func captureTimeParseOffsetAndSubsecondInvariants(seed: UInt64) throws {
        var rng = SeededRNG(seed: seed)

        for step in 0..<200 {
            let year = rng.int(in: 2000...2035)
            let month = rng.int(in: 1...12)
            let day = rng.int(in: 1...28)
            let hour = rng.int(in: 0...23)
            let minute = rng.int(in: 0...59)
            let second = rng.int(in: 0...58)
            let offHours = rng.int(in: -11...11)
            let offMins = rng.pick([0, 30])
            let sign = offHours >= 0 ? "+" : "-"
            let offsetStr = String(format: "%@%02d:%02d", sign, abs(offHours), offMins)
            let offsetSeconds = (offHours >= 0 ? 1 : -1) * (abs(offHours) * 3600 + offMins * 60)

            let base = String(format: "%04d:%02d:%02d %02d:%02d:%02d", year, month, day, hour, minute, second)
            let nextSec = String(format: "%04d:%02d:%02d %02d:%02d:%02d", year, month, day, hour, minute, second + 1)

            let dUTC = try #require(CaptureTime.parse(dateTimeOriginal: base, offset: "+00:00"))
            let dOff = try #require(CaptureTime.parse(dateTimeOriginal: base, offset: offsetStr))
            let dNext = try #require(CaptureTime.parse(dateTimeOriginal: nextSec, offset: "+00:00"))
            let dSub = try #require(CaptureTime.parse(dateTimeOriginal: base, subseconds: "50", offset: "+00:00"))

            // Same wall clock at +offset is `offsetSeconds` earlier in UTC epoch.
            #expect(abs(dUTC.timeIntervalSince(dOff) - Double(offsetSeconds)) < 1e-6,
                    "seed=\(hex(seed)) step=\(step): offset arithmetic mismatch for \(offsetStr)")
            #expect(abs(dNext.timeIntervalSince(dUTC) - 1.0) < 1e-6,
                    "seed=\(hex(seed)) step=\(step): +1s mismatch")
            #expect(abs(dSub.timeIntervalSince(dUTC) - 0.5) < 1e-6,
                    "seed=\(hex(seed)) step=\(step): subsecond 0.5s mismatch")
        }
    }
}
