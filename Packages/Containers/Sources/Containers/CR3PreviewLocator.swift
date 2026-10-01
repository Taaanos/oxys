import Foundation

/// Canon CR3 (ISO base media file format). Three kinds of JPEG, none of them in the TIFF sense:
/// - `THMB` in Canon's `uuid 85c0b687…` box inside `moov` (160×120);
/// - `PRVW` in the top-level `uuid eaf42b5e…` box (about 1620×1080), after 8 extra bytes
///   that follow the UUID;
/// - the full-size JPEG, which is the single sample of a `trak` whose data sits in `mdat`,
///   found through that track's `stsz` and `stco`/`co64`. Raw tracks (`CRAW`) are the other tracks.
///
/// `THMB` and `PRVW` carry a few fixed fields (dimensions, size) before the JPEG; the JPEG is
/// found by its SOI near the start of the payload rather than by trusting one layout.
/// Orientation, make and model come from `CMT1`, which holds a small TIFF with IFD0.
/// Checked against one real file (EOS R6 Mark III); older CR3 bodies are unverified.
public enum CR3PreviewLocator {
    private static let canonMetadataUUID = Data([0x85, 0xC0, 0xB6, 0x87, 0x82, 0x0F, 0x11, 0xE0, 0x81, 0x11, 0xF4, 0xCE, 0x46, 0x2B, 0x6A, 0x48])
    private static let canonPreviewUUID = Data([0xEA, 0xF4, 0x2B, 0x5E, 0x1C, 0x98, 0x4B, 0x88, 0xB9, 0xFB, 0xB7, 0xDC, 0x40, 0x6E, 0x4D, 0x16])

    private struct Box {
        var type: String
        var payload: Int
        var end: Int
    }

    private static func isBoxType(_ s: String) -> Bool {
        s.utf8.count == 4 && s.utf8.allSatisfy { ($0 >= 0x20 && $0 < 0x7F) }
    }

    private static func boxes(_ reader: ByteReader, in range: Range<Int>) -> [Box] {
        var result: [Box] = []
        var pos = range.lowerBound
        while pos + 8 <= range.upperBound {
            guard let size32 = reader.u32(pos), let typeBytes = reader.bytes(pos + 4, 4) else { break }
            var size = Int(size32)
            var payload = pos + 8
            if size == 1 {
                guard let big = reader.u64(pos + 8) else { break }
                size = Int(clamping: big); payload = pos + 16
            } else if size == 0 {
                size = range.upperBound - pos
            }
            // `size` can be near Int.max (64-bit largesize), so the end must be computed overflow-safe:
            // a bare `+` would trap and crash the process on a crafted file.
            let (end, overflowed) = pos.addingReportingOverflow(size)
            guard size >= payload - pos, !overflowed, end <= range.upperBound else { break }
            result.append(Box(type: String(decoding: typeBytes, as: UTF8.self), payload: payload, end: end))
            pos = end
        }
        return result
    }

    public static func locate(in data: Data) -> LocatedPreviews? {
        let reader = ByteReader(data: data, order: .big)
        guard reader.bytes(4, 4) == Data("ftyp".utf8), reader.bytes(8, 4) == Data("crx ".utf8) else { return nil }
        var previews: [EmbeddedJPEG] = []
        var info = ContainerInfo(make: "Canon")
        var trackNumber = 0

        func addJPEG(_ location: String, at offset: Int, length: Int?) {
            guard let header = JPEGHeader.parse(reader, at: offset), !header.isLossless else { return }
            let len = length ?? 0
            let (end, overflowed) = offset.addingReportingOverflow(len)
            guard len > 4, !overflowed, end <= reader.count else { return }
            previews.append(EmbeddedJPEG(location: location, offset: offset, length: len,
                                         width: header.width, height: header.height,
                                         containerOrientation: nil, header: header))
        }

        func jpegInPayload(_ box: Box) {
            for delta in 0..<64 where reader.u8(box.payload + delta) == 0xFF && reader.u8(box.payload + delta + 1) == 0xD8 {
                // The size field sits just before the JPEG in both THMB and PRVW; fall back to the box end.
                let declared = reader.u32(box.payload + delta - 4).map(Int.init)
                let offset = box.payload + delta
                let length = (declared.map { $0 > 4 && $0 <= box.end - offset } == true) ? declared : box.end - offset
                addJPEG(box.type, at: offset, length: length)
                return
            }
        }

        /// First sample of a track: its size from `stsz`, its offset from `stco` or `co64`.
        func firstSample(ofTrack trak: Box) -> (offset: Int, size: Int)? {
            var size: Int?
            var offset: Int?
            func descend(_ range: Range<Int>) {
                for b in boxes(reader, in: range) {
                    switch b.type {
                    case "mdia", "minf", "stbl": descend(b.payload..<b.end)
                    case "stsz":
                        // version/flags, sample_size, sample_count, [entry_size...]
                        if let fixed = reader.u32(b.payload + 4).map(Int.init) {
                            size = fixed != 0 ? fixed : reader.u32(b.payload + 12).map(Int.init)
                        }
                    case "stco": offset = reader.u32(b.payload + 8).map(Int.init)
                    case "co64": offset = reader.u64(b.payload + 8).map { Int(clamping: $0) }
                    default: break
                    }
                }
            }
            descend(trak.payload..<trak.end)
            guard let size, let offset else { return nil }
            return (offset, size)
        }

        func visit(_ range: Range<Int>) {
            for box in boxes(reader, in: range) {
                switch box.type {
                case "moov":
                    visit(box.payload..<box.end)
                case "trak":
                    trackNumber += 1
                    if let (offset, size) = firstSample(ofTrack: box), reader.u8(offset) == 0xFF, reader.u8(offset + 1) == 0xD8 {
                        addJPEG("Track\(trackNumber)", at: offset, length: size)
                    }
                case "uuid":
                    guard let id = reader.bytes(box.payload, 16) else { break }
                    let body = box.payload + 16
                    if id == canonMetadataUUID {
                        visit(body..<box.end)
                    } else if id == canonPreviewUUID {
                        // 8 bytes (version and count) precede the child boxes.
                        let skip = boxes(reader, in: body..<box.end).first.map { isBoxType($0.type) } == true ? 0 : 8
                        visit((body + skip)..<box.end)
                    }
                case "CMT1":
                    if let tiff = reader.bytes(box.payload, box.end - box.payload),
                       let main = TIFFPreviewLocator.locate(in: tiff)?.info {
                        info.make = main.make ?? info.make
                        info.model = main.model
                        info.orientation = main.orientation
                    }
                case "THMB", "PRVW":
                    jpegInPayload(box)
                default:
                    break
                }
            }
        }
        visit(0..<reader.count)
        guard !previews.isEmpty else { return nil }
        // CR3 JPEGs carry no orientation of their own; the container's applies to all.
        previews = previews.map { var p = $0; p.containerOrientation = info.orientation; return p }
        return LocatedPreviews(format: "CR3", info: info, previews: previews, skipped: [])
    }
}
