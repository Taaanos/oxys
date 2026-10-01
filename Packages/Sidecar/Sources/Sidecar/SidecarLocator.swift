import Foundation

/// Where a sidecar lives relative to its photo (PRD "Sidecar naming").
public enum SidecarNaming: String, Sendable, CaseIterable {
    /// `IMG_0001.xmp` for `IMG_0001.ARW` (Lightroom, FastRawViewer). The default.
    case stem
    /// `IMG_0001.ARW.xmp` (darktable style; RawTherapee can use it).
    case fullName

    public var other: SidecarNaming { self == .stem ? .fullName : .stem }

    /// The sidecar's file name for a photo's file name.
    public func fileName(for photoName: String) -> String {
        switch self {
        case .fullName: photoName + ".xmp"
        case .stem: (photoName as NSString).deletingPathExtension + ".xmp"
        }
    }
}

/// The sidecar files found for one photo.
public struct SidecarFiles: Sendable, Hashable {
    /// The file Oxys reads from and (M-08) writes to: the one in the configured style, else the other style.
    public var primary: URL
    /// The other style's file when both exist. Shown in the inspector, never read.
    public var alsoPresent: URL?
}

/// Finds sidecars with one directory listing for the whole folder, not one `stat` per photo.
public struct SidecarIndex: Sendable {
    /// Lowercased file name to actual URL. APFS and HFS+ are case-insensitive by default, so lookups must be too.
    private let xmpFiles: [String: URL]

    public init(folder: URL) {
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        var index: [String: URL] = [:]
        for url in entries where url.pathExtension.lowercased() == "xmp" {
            index[url.lastPathComponent.lowercased()] = url
        }
        xmpFiles = index
    }

    public func files(for photo: URL, preferring style: SidecarNaming) -> SidecarFiles? {
        let name = photo.lastPathComponent
        let preferred = xmpFiles[style.fileName(for: name).lowercased()]
        let other = xmpFiles[style.other.fileName(for: name).lowercased()]
        switch (preferred, other) {
        case let (p?, o?) where p != o: return SidecarFiles(primary: p, alsoPresent: o)
        case let (p?, _): return SidecarFiles(primary: p)
        case let (nil, o?): return SidecarFiles(primary: o)
        case (nil, nil): return nil
        }
    }
}
