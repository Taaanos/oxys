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
    /// Stars, reject and label. Saved to the sidecar on every change (M-08).
    public var decision: Decision = .none
    /// Where the decision was read from, and anything the inspector should say about it (M-07).
    public var sidecar: SidecarInfo = SidecarInfo()

    /// The camera JPEG or HEIC that came with this RAW, when pairing found one (V-10). The frame is the RAW's:
    /// its URL, sidecar and hand-off. The companion is what the photographer sees, and goes along to Finder.
    public var companion: Companion?

    public struct Companion: Sendable, Hashable {
        public let url: URL
        public let format: PhotoFormat
        public let fileSize: Int
        public let modificationDate: Date
    }

    public var id: URL { url }
    public var name: String { url.lastPathComponent }

    public var isPair: Bool { companion != nil }
    /// The file whose pixels Loupe, Compare and Grid show: the companion of a pair, else the photo itself.
    public var shownURL: URL { companion?.url ?? url }
    public var shownFormat: PhotoFormat { companion?.format ?? format }
    public var shownFileSize: Int { companion?.fileSize ?? fileSize }
    public var shownModificationDate: Date { companion?.modificationDate ?? modificationDate }
    /// True when the pixels on screen come from a RAW container (a pair shows its JPEG, so it does not).
    public var showsRaw: Bool { shownFormat.isRaw }
    /// Every file of the frame, for Reveal in Finder: the RAW, then the companion.
    public var files: [URL] { companion.map { [url, $0.url] } ?? [url] }

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
