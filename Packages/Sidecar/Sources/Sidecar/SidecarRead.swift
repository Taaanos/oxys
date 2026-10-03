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

/// The outcome of reading a file that should be a sidecar (B-5).
enum SidecarBytes: Equatable {
    case missing
    /// A FIFO, a device, a socket or a folder.
    case notRegular
    case tooLarge
    case data(Data)
}

public enum SidecarReader {
    /// A sanity bound: a sidecar is a few KB; anything much larger is not one.
    static let maxBytes = 8 * 1024 * 1024

    /// Reads `url` only when it is a regular file of at most `maxBytes`. The check runs on the open descriptor, so
    /// a file that changes after a path check cannot get past it. `O_NONBLOCK` makes `open` on a FIFO return at
    /// once instead of waiting for a writer. Links are followed (the writer refuses them; the reader may show them).
    static func readBounded(_ url: URL) throws -> SidecarBytes {
        let fd = open(url.path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else {
            if errno == ENOENT { return .missing }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        guard (info.st_mode & S_IFMT) == S_IFREG else { return .notRegular }
        guard info.st_size <= maxBytes else { return .tooLarge }
        var data = Data(count: Int(info.st_size))
        var offset = 0
        try data.withUnsafeMutableBytes { buffer in
            while offset < buffer.count {
                let n = Darwin.read(fd, buffer.baseAddress! + offset, buffer.count - offset)
                if n < 0 { if errno == EINTR { continue }; throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                if n == 0 { break }
                offset += n
            }
        }
        // The file may have shrunk since fstat. A file that grew is cut at the size we checked.
        return .data(offset == data.count ? data : data.prefix(offset))
    }

    public static func read(photo: URL, embeddedFallback: Bool, index: SidecarIndex,
                            naming: SidecarNaming) -> SidecarReadResult {
        if let files = index.files(for: photo, preferring: naming) {
            do {
                switch try readBounded(files.primary) {
                case .data(let data): return .sidecar(files, try XMPReader.parse(data))
                case .tooLarge: return .malformed(files, reason: "File is too large to be a sidecar")
                case .notRegular: return .malformed(files, reason: "Sidecar is not a regular file")
                case .missing: return .none
                }
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
