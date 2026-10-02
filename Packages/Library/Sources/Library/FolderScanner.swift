import Diagnostics
import Foundation
import Metadata

/// What a folder holds. Lists files only; reading capture times is a separate, later step so the list appears at once.
public enum FolderScanner {
    public struct Result: Sendable {
        public var photos: [Photo]
        /// Set when `photos` is empty but a subfolder (up to `hintDepth` levels down, as on a card's `DCIM/100XXXXX`) holds some (G-4).
        public var subfolderHasPhotos: Bool
    }

    static let hintDepth = 3

    /// With `pairing`, a RAW and its camera JPEG or HEIC come back as one photo (V-10).
    public static func scan(_ folder: URL, pairing: Bool = true) throws -> Result {
        let token = Perf.begin(.folderScan)
        defer { Perf.end(token) }
        var photos = try list(folder)
        if pairing { photos = RawJpegPairing.pair(photos) }
        photos.sort(by: Photo.isOrderedBefore)   // modification date for now; capture times re-sort later
        return Result(photos: photos, subfolderHasPhotos: photos.isEmpty && hasPhotos(inSubfoldersOf: folder, depth: hintDepth))
    }

    static func list(_ folder: URL) throws -> [Photo] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        let entries = try FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])
        var photos: [Photo] = []
        photos.reserveCapacity(entries.count)
        for url in entries {
            let name = url.lastPathComponent
            // `.skipsHiddenFiles` covers dot-files, but AppleDouble `._*` files are dot-files only by name
            // and exFAT cards are full of them, so the check is explicit.
            guard !name.hasPrefix("."),
                  let format = PhotoFormat(pathExtension: url.pathExtension),
                  let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true else { continue }
            photos.append(Photo(url: url, format: format,
                                fileSize: values.fileSize ?? 0,
                                modificationDate: values.contentModificationDate ?? .distantPast))
        }
        return photos
    }

    static func hasPhotos(inSubfoldersOf folder: URL, depth: Int) -> Bool {
        guard depth > 0,
              let entries = try? FileManager.default.contentsOfDirectory(
                at: folder, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
        else { return false }
        for url in entries where (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            if let photos = try? list(url), !photos.isEmpty { return true }
            if hasPhotos(inSubfoldersOf: url, depth: depth - 1) { return true }
        }
        return false
    }

    /// Reads capture times for `photos` with at most `width` files in flight and returns them in the order of `photos`.
    public static func captureTimes(for photos: [Photo], width: Int = 8) async -> [Date?] {
        let token = Perf.begin(.captureTimes)
        defer { Perf.end(token) }
        let urls = photos.map(\.url)
        return await withTaskGroup(of: (Int, Date?).self) { group in
            var times = [Date?](repeating: nil, count: urls.count)
            var next = 0
            func addNext() {
                guard next < urls.count else { return }
                let (index, url) = (next, urls[next])
                next += 1
                group.addTask { (index, CaptureTime.read(from: url)) }
            }
            for _ in 0..<min(width, urls.count) { addNext() }
            while let (index, time) = await group.next() {
                times[index] = time
                addNext()
            }
            return times
        }
    }
}
