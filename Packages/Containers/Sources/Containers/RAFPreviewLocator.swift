import Foundation

/// Fujifilm RAF: the embedded JPEG's offset and length sit in the fixed big-endian header
/// (0x54 and 0x58). The JPEG carries its own Exif, including orientation.
public enum RAFPreviewLocator {
    private static let magic = Data("FUJIFILMCCD-RAW ".utf8)

    public static func locate(in data: Data) -> LocatedPreviews? {
        let reader = ByteReader(data: data, order: .big)
        guard reader.bytes(0, 16) == magic,
              let offset = reader.u32(0x54).map(Int.init), let length = reader.u32(0x58).map(Int.init),
              length > 4, offset >= 0, offset + length <= reader.count,
              let header = JPEGHeader.parse(reader, at: offset) else { return nil }
        var info = ContainerInfo()
        if let model = reader.bytes(0x1C, 32) {
            info.model = String(decoding: model.prefix { $0 != 0 }, as: UTF8.self)
        }
        info.make = "FUJIFILM"
        info.orientation = header.exifOrientation
        let preview = EmbeddedJPEG(location: "RAF", offset: offset, length: length,
                                   width: header.width, height: header.height,
                                   containerOrientation: header.exifOrientation, header: header)
        return LocatedPreviews(format: "RAF", info: info, previews: [preview], skipped: [])
    }
}
