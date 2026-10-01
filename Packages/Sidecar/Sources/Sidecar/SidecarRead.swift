import Foundation
import ImageIO

/// What reading one photo's metadata source found.
public enum SidecarReadResult: Sendable, Hashable {
    /// No sidecar and nothing embedded.
    case none
    /// A sidecar parsed. `properties` may be empty (a sidecar with only develop settings).
    case sidecar(SidecarFiles, XMPProperties)
    /// A sidecar exists but could not be parsed. M-08 must not overwrite it blindly.
    case malformed(SidecarFiles, reason: String)
    /// No sidecar; the file itself carries a rating or label (JPEG, DNG, TIFF, HEIC; G-8). Read-only.
    case embedded(XMPProperties)
}

public enum SidecarReader {
    /// A sanity bound: a sidecar is a few KB; anything much larger is not one.
    static let maxBytes = 8 * 1024 * 1024

    public static func read(photo: URL, embeddedFallback: Bool, index: SidecarIndex,
                            naming: SidecarNaming) -> SidecarReadResult {
        if let files = index.files(for: photo, preferring: naming) {
            do {
                let data = try Data(contentsOf: files.primary, options: .mappedIfSafe)
                guard data.count <= maxBytes else { return .malformed(files, reason: "File is too large to be a sidecar") }
                return .sidecar(files, try XMPReader.parse(data))
            } catch let error as XMPParseError {
                return .malformed(files, reason: error.message)
            } catch {
                return .malformed(files, reason: error.localizedDescription)
            }
        }
        if embeddedFallback, let props = embeddedProperties(of: photo) { return .embedded(props) }
        return .none
    }

    /// Rating and label stored inside the image (Lightroom writes there for JPEG, DNG, TIFF). ImageIO reads only
    /// the metadata block, not the pixels.
    static func embeddedProperties(of url: URL) -> XMPProperties? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let metadata = CGImageSourceCopyMetadataAtIndex(source, 0, nil) else { return nil }
        var props = XMPProperties()
        if let tag = CGImageMetadataCopyTagWithPath(metadata, nil, "xmp:Rating" as CFString),
           let value = CGImageMetadataTagCopyValue(tag) {
            let text = (value as? String) ?? "\(value)"
            if let n = Int(text.trimmingCharacters(in: .whitespaces)) { props.rating = min(max(n, -1), 5) }
        }
        if let tag = CGImageMetadataCopyTagWithPath(metadata, nil, "xmp:Label" as CFString),
           let value = CGImageMetadataTagCopyValue(tag) as? String, !value.isEmpty {
            props.label = value
        }
        return props == XMPProperties() ? nil : props
    }
}
