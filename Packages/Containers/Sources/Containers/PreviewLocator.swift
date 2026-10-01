import Foundation

/// Entry point: sniffs the container and runs the matching locator on memory-mapped bytes.
public enum PreviewLocator {
    public static func locate(in data: Data) -> LocatedPreviews? {
        TIFFPreviewLocator.locate(in: data)
            ?? RAFPreviewLocator.locate(in: data)
            ?? CR3PreviewLocator.locate(in: data)
    }

    public static func locate(at url: URL) throws -> LocatedPreviews? {
        locate(in: try Data(contentsOf: url, options: .alwaysMapped))
    }

    /// The JPEG bytes of one located preview.
    public static func bytes(of preview: EmbeddedJPEG, in data: Data) -> Data {
        data.subdata(in: (data.startIndex + preview.offset)..<(data.startIndex + preview.offset + preview.length))
    }
}
