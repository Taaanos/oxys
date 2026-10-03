import Foundation
import ImageIO

/// What a developed export keeps of the RAW's metadata, and what it must change (V-21). The developed pixels are
/// upright and have a new size, and they are not a RAW any more, so what describes the RAW's own layout, or how to
/// develop it, must not travel along.
public enum ExportMetadata {
    /// The TIFF tags that describe the photo. What describes the RAW's pixels (tile size, photometric
    /// interpretation, strips, compression) is left out.
    static var tiffKept: [CFString] { [
        kCGImagePropertyTIFFMake, kCGImagePropertyTIFFModel, kCGImagePropertyTIFFSoftware, kCGImagePropertyTIFFDateTime,
        kCGImagePropertyTIFFArtist, kCGImagePropertyTIFFCopyright, kCGImagePropertyTIFFImageDescription,
        kCGImagePropertyTIFFHostComputer,
    ] }

    /// Image properties for the encoder, from the RAW's own (`CGImageSourceCopyPropertiesAtIndex`): Exif, GPS, IPTC
    /// and the descriptive TIFF tags. Orientation is 1 (the pixels are already upright) and the Exif pixel size is
    /// the output's. The Exif color space tag is left to the encoder, which knows the profile it embeds.
    public static func properties(from source: [CFString: Any], width: Int, height: Int) -> [CFString: Any] {
        var out: [CFString: Any] = [kCGImagePropertyOrientation: 1]
        if var exif = source[kCGImagePropertyExifDictionary] as? [CFString: Any] {
            exif[kCGImagePropertyExifColorSpace] = nil
            exif[kCGImagePropertyExifPixelXDimension] = width
            exif[kCGImagePropertyExifPixelYDimension] = height
            out[kCGImagePropertyExifDictionary] = exif
        } else {
            out[kCGImagePropertyExifDictionary] = [
                kCGImagePropertyExifPixelXDimension: width, kCGImagePropertyExifPixelYDimension: height,
            ] as [CFString: Any]
        }
        if let tiff = source[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
            var kept: [CFString: Any] = [kCGImagePropertyTIFFOrientation: 1]
            for key in tiffKept { if let v = tiff[key] { kept[key] = v } }
            out[kCGImagePropertyTIFFDictionary] = kept
        }
        for key in [kCGImagePropertyGPSDictionary, kCGImagePropertyIPTCDictionary] {
            if let v = source[key] { out[key] = v }
        }
        return out
    }

    /// The camera-raw develop settings namespace (`crs:`). They say how to develop the RAW. In a file that is already
    /// developed, an editor would apply them a second time.
    static let developSettingsNamespace = "http://ns.adobe.com/camera-raw-settings/1.0/"
    /// XMP tags that describe the RAW's pixel layout, not the developed file's.
    static let layoutTags: Set<String> = ["tiff:Orientation", "tiff:ImageWidth", "tiff:ImageLength",
                                          "exif:PixelXDimension", "exif:PixelYDimension"]

    /// The XMP of a sidecar or a DNG for a developed file: rating, label, keywords, title and the like stay; the
    /// develop settings and the layout tags are removed. Nil when the packet cannot be read.
    public static func developedXMP(from packet: Data) -> CGImageMetadata? {
        guard let parsed = CGImageMetadataCreateFromXMPData(doubleQuoted(trimmed(packet)) as CFData),
              let metadata = CGImageMetadataCreateMutableCopy(parsed),
              let tags = CGImageMetadataCopyTags(metadata) as? [CGImageMetadataTag] else { return nil }
        for tag in tags {
            guard let prefix = CGImageMetadataTagCopyPrefix(tag) as String?,
                  let name = CGImageMetadataTagCopyName(tag) as String? else { continue }
            let namespace = CGImageMetadataTagCopyNamespace(tag) as String?
            if namespace == developSettingsNamespace || layoutTags.contains("\(prefix):\(name)") {
                CGImageMetadataRemoveTagWithPath(metadata, nil, "\(prefix):\(name)" as CFString)
            }
        }
        return metadata
    }

    /// `packet` cut to what lies between the start of its `<?xpacket begin` (or `<x:xmpmeta`) and the end of its
    /// `<?xpacket end ... ?>`. A RAW's XMP tag often counts bytes past the packet (a Sony ARW's runs into its PrintIM
    /// block), and the parser refuses a packet with such a tail.
    static func trimmed(_ packet: Data) -> Data {
        let bytes = Data(packet)
        let starts = ["<?xpacket begin", "<x:xmpmeta"].compactMap { bytes.range(of: Data($0.utf8))?.lowerBound }
        let begin = starts.min() ?? bytes.startIndex
        var end = bytes.endIndex
        if let marker = bytes.range(of: Data("<?xpacket end".utf8), options: .backwards),
           let close = bytes.range(of: Data("?>".utf8), in: marker.upperBound..<bytes.endIndex) {
            end = close.upperBound
        } else if let close = bytes.range(of: Data("</x:xmpmeta>".utf8), options: .backwards) {
            end = close.upperBound
        }
        return begin < end ? bytes[begin..<end] : bytes
    }

    /// `packet` with every attribute inside a tag written with double quotes. Valid XML allows single quotes (Sony and
    /// several other writers use them), but the ImageIO parser rejects them. Text between tags is left alone.
    static func doubleQuoted(_ packet: Data) -> Data {
        guard let text = String(data: packet, encoding: .utf8), text.contains("'"),
              let tags = try? NSRegularExpression(pattern: "<[^<>]*>"),
              let attribute = try? NSRegularExpression(pattern: "(\\s[A-Za-z_][\\w:.-]*\\s*=\\s*)'([^']*)'") else { return packet }
        var out = ""
        var cursor = text.startIndex
        let whole = NSRange(text.startIndex..., in: text)
        for match in tags.matches(in: text, range: whole) {
            guard let range = Range(match.range, in: text) else { continue }
            out += text[cursor..<range.lowerBound]
            let tag = String(text[range])
            var fixed = ""
            var last = tag.startIndex
            for m in attribute.matches(in: tag, range: NSRange(tag.startIndex..., in: tag)) {
                guard let all = Range(m.range, in: tag), let name = Range(m.range(at: 1), in: tag), let value = Range(m.range(at: 2), in: tag) else { continue }
                fixed += tag[last..<all.lowerBound] + tag[name] + "\"" + tag[value].replacingOccurrences(of: "\"", with: "&quot;") + "\""
                last = all.upperBound
            }
            out += fixed + tag[last...]
            cursor = range.upperBound
        }
        out += text[cursor...]
        return Data(out.utf8)
    }

    /// The XMP packet bytes of `metadata`, for a JPEG's APP1 segment.
    public static func packet(of metadata: CGImageMetadata) -> Data? {
        CGImageMetadataCreateXMPData(metadata, nil) as Data?
    }
}
