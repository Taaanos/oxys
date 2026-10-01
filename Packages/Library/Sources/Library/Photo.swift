import Foundation

public enum PhotoFormat: String, Sendable, CaseIterable {
    case arw, cr2, cr3, nef, raf, dng, orf, rw2, pef
    case jpeg, heic, tiff

    public var isRaw: Bool {
        switch self {
        case .jpeg, .heic, .tiff: false
        default: true
        }
    }

    /// Formats whose files can carry XMP inside (Lightroom writes there instead of a sidecar, G-8).
    public var hasEmbeddedXMP: Bool {
        switch self {
        case .jpeg, .heic, .tiff, .dng: true
        default: false
        }
    }

    /// The format for a file extension in any case, or nil when Oxys does not handle it.
    public init?(pathExtension: String) {
        switch pathExtension.lowercased() {
        case "jpg", "jpeg": self = .jpeg
        case "heic": self = .heic
        case "tif", "tiff": self = .tiff
        case let ext: self.init(rawValue: ext)
        }
    }
}

/// The image Loupe shows for a photo, as read from the file (M-02). Upright pixel size, orientation applied.
public struct PreviewInfo: Sendable, Hashable {
    public let pixelWidth: Int
    public let pixelHeight: Int

    public init(pixelWidth: Int, pixelHeight: Int) {
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
    }
}

public struct Photo: Sendable, Identifiable, Hashable {
    public let url: URL
    public let format: PhotoFormat
    public let fileSize: Int
    public let modificationDate: Date
    /// From EXIF `DateTimeOriginal`. Nil until the background read finishes, and for frames that have none.
    public var captureTime: Date?
    /// Set once the preview has been opened; nil until then, and for files that have none.
    public var preview: PreviewInfo?
    /// Stars, reject and label. In memory until M-08 saves it.
    public var decision: Decision = .none
    /// Where the decision was read from, and anything the inspector should say about it (M-07).
    public var sidecar: SidecarInfo = SidecarInfo()

    public var id: URL { url }
    public var name: String { url.lastPathComponent }

    /// The time the photo sorts by: capture time, else the file's modification date (screenshots, exported JPEGs).
    public var sortDate: Date { captureTime ?? modificationDate }

    public init(url: URL, format: PhotoFormat, fileSize: Int, modificationDate: Date, captureTime: Date? = nil) {
        self.url = url
        self.format = format
        self.fileSize = fileSize
        self.modificationDate = modificationDate
        self.captureTime = captureTime
    }

    /// Capture time, then filename (Finder-style numeric ordering, so IMG_2 comes before IMG_10).
    public static func isOrderedBefore(_ a: Photo, _ b: Photo) -> Bool {
        if a.sortDate != b.sortDate { return a.sortDate < b.sortDate }
        return a.name.localizedStandardCompare(b.name) == .orderedAscending
    }
}
