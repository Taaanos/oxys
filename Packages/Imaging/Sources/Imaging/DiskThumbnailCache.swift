import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Small decoded previews kept on disk so a frame can be shown at once while the full preview loads, and so
/// Grid never re-reads the RAW (M-04). Entries are keyed by path, size and modification date (a changed file
/// misses), live in the caches directory (never the photo folder, G-7) and are evicted least recently used
/// first once the total passes the cap.
public final class DiskThumbnailCache: @unchecked Sendable {
    public struct Thumbnail: @unchecked Sendable {
        public let image: CGImage
        public let orientation: CGImagePropertyOrientation
    }

    public let directory: URL
    public let byteCap: Int
    private let lock = NSLock()
    private var writesSinceTrim = 0

    /// `directory` is created on demand. `byteCap` defaults to 2 GB (M-04 open question 2).
    public init(directory: URL, byteCap: Int = 2 << 30) {
        self.directory = directory
        self.byteCap = byteCap
    }

    /// `~/Library/Caches/<bundle id>/thumbnails`.
    public static func standardDirectory(bundleID: String) -> URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return caches.appendingPathComponent(bundleID, isDirectory: true).appendingPathComponent("thumbnails", isDirectory: true)
    }

    /// `variant` names a different way of making the same edge (V-20: a 160 px strip thumbnail scaled from a real
    /// preview, not taken from the camera's padded one), so the two never share an entry. Empty for Grid's.
    public func fileURL(path: String, size: Int, modified: Date, longEdge: Int, variant: String = "") -> URL {
        let key = "\(path)|\(size)|\(modified.timeIntervalSince1970)|\(longEdge)" + (variant.isEmpty ? "" : "|\(variant)")
        let name = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(name + ".jpg")
    }

    /// The cached thumbnail, or nil on a miss. A hit counts as a use for eviction.
    public func thumbnail(path: String, size: Int, modified: Date, longEdge: Int, variant: String = "") -> Thumbnail? {
        let file = fileURL(path: path, size: size, modified: modified, longEdge: longEdge, variant: variant)
        guard let source = CGImageSourceCreateWithURL(file as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
        else { return nil }
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let raw = props?[kCGImagePropertyOrientation] as? UInt32
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: file.path)
        return Thumbnail(image: image, orientation: raw.flatMap(CGImagePropertyOrientation.init(rawValue:)) ?? .up)
    }

    /// Stores `image` (stored unrotated, with the orientation still to apply). Failures are silent: the cache
    /// is an optimization.
    public func store(_ image: CGImage, orientation: CGImagePropertyOrientation, path: String, size: Int,
                      modified: Date, longEdge: Int, variant: String = "") {
        let file = fileURL(path: path, size: size, modified: modified, longEdge: longEdge, variant: variant)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil)
        else { return }
        let props: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 0.85,
                                      kCGImagePropertyOrientation: orientation.rawValue]
        CGImageDestinationAddImage(destination, image, props as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return }
        try? (data as Data).write(to: file, options: .atomic)
        lock.lock()
        writesSinceTrim += 1
        let due = writesSinceTrim >= 64
        if due { writesSinceTrim = 0 }
        lock.unlock()
        if due { trim() }
    }

    /// Deletes the least recently used files until the total is within the cap.
    public func trim() {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey]
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys)
        else { return }
        var entries: [(url: URL, date: Date, size: Int)] = files.compactMap { url in
            guard url.pathExtension == "jpg", let v = try? url.resourceValues(forKeys: Set(keys)) else { return nil }
            return (url, v.contentModificationDate ?? .distantPast, v.fileSize ?? 0)
        }
        var total = entries.reduce(0) { $0 + $1.size }
        guard total > byteCap else { return }
        entries.sort { $0.date < $1.date }
        for entry in entries where total > byteCap {
            try? FileManager.default.removeItem(at: entry.url)
            total -= entry.size
        }
    }

    /// Deletes every thumbnail (V-23). Only `.jpg` files directly in `directory` go; the folder itself and
    /// anything beside it stay. Safe while loads run: a read of a removed file is a miss and the thumbnail is
    /// built again. Returns the bytes freed.
    @discardableResult
    public func clear() -> Int {
        let keys: [URLResourceKey] = [.fileSizeKey]
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys)
        else { return 0 }
        var freed = 0
        for url in files where url.pathExtension == "jpg" {
            let size = (try? url.resourceValues(forKeys: Set(keys)).fileSize) ?? 0
            if (try? FileManager.default.removeItem(at: url)) != nil { freed += size }
        }
        lock.lock()
        writesSinceTrim = 0
        lock.unlock()
        return freed
    }

    public var totalBytes: Int {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return files.reduce(0) { $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
    }
}
