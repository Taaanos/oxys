import Canvas
import CoreGraphics
import CoreImage
import ImageIO
import Diagnostics
import Foundation
import Imaging
import Library

/// What the pipeline holds per photo: the uploaded texture and the size of the preview it came from.
nonisolated struct LoupeFrame: Sendable {
    let image: PreparedImage
    let width: Int
    let height: Int
    /// Computed with the frame, so a prefetched frame has its histogram ready (M-17); nil if it could not be.
    let histogram: Histogram?
}

/// The pipeline's work for one photo: map the file, decode the embedded preview, upload it. Checks for
/// cancellation between the steps, so a request that was superseded stops before the next expensive one.
nonisolated enum FrameLoader {
    /// Long edge of the disk thumbnails, which double as Loupe's stand-in while a full preview loads.
    static let thumbnailEdge = 512

    /// One disk cache for Loupe's stand-ins and Grid's thumbnails, so a photo is decoded for them once.
    static let sharedThumbnails = DiskThumbnailCache(
        directory: DiskThumbnailCache.standardDirectory(bundleID: Bundle.main.bundleIdentifier ?? "dev.oxys.Oxys"))

    static func key(for photo: Photo) -> FrameKey {
        FrameKey(url: photo.shownURL, fileSize: photo.shownFileSize, modified: photo.shownModificationDate, isRaw: photo.showsRaw)
    }

    /// Developer hook for slow media (G-11, P-01): `OXYS_BENCH_DELAY_MS=<n>` makes every frame load wait n ms before
    /// it reads, as an SD card or a network share would. The wait is cut into steps, so a cancelled load stops at once.
    private static let readDelay: Int = Int(ProcessInfo.processInfo.environment["OXYS_BENCH_DELAY_MS"] ?? "") ?? 0

    private static func simulateSlowRead() throws {
        var left = readDelay
        while left > 0 {
            try Task.checkCancellation()
            let step = min(left, 5)
            usleep(UInt32(step) * 1000)
            left -= step
        }
    }

    /// P-02: the preview is decoded once, straight into the upload buffer (it is handed over undecoded), and the
    /// histogram and the 512 px thumbnail are made from the pixels in that buffer beside the GPU copy. Nothing
    /// blocks a pool thread: the GPU copy is awaited. Cancellation is checked between the steps, and once more
    /// after the decode, before the GPU copy is queued.
    static func load(_ key: FrameKey, thumbnails: DiskThumbnailCache) async throws -> LoadedFrame<LoupeFrame> {
        do {
            try Task.checkCancellation()
            try simulateSlowRead()
            let source = try PreviewSource.open(key.url, isRaw: key.isRaw)
            try Task.checkCancellation()
            let decoded = try source.decodeLoupe(maxPixelSize: 8192, deferred: true)
            try Task.checkCancellation()
            guard let gpu = LoupeGPU.shared else { throw PreviewError.corrupt }
            let thumbnailFile = thumbnails.fileURL(path: key.url.path, size: key.fileSize, modified: key.modified,
                                                   longEdge: thumbnailEdge)
            let needsThumbnail = !FileManager.default.fileExists(atPath: thumbnailFile.path)
            let uploaded = try await gpu.prepare(decoded.image, orientation: decoded.orientation) { pixels in
                (histogram: Perf.measure(.histogram) { Histogram.compute(pixels.image, source: .preview) },
                 thumbnail: needsThumbnail ? pixels.image.downscaled(longEdge: thumbnailEdge) : nil)
            }
            guard let (prepared, extras) = uploaded else { throw PreviewError.corrupt }
            let size = decoded.sourceDisplaySize
            if let thumbnail = extras.thumbnail {
                storeThumbnail(thumbnail, orientation: decoded.orientation, key: key, into: thumbnails)
            }
            return LoadedFrame(frame: LoupeFrame(image: prepared, width: size.width, height: size.height,
                                                 histogram: extras.histogram),
                               cost: prepared.byteCost)
        } catch let error as PreviewError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw PreviewError.corrupt
        }
    }

    /// Writes the 512 px thumbnail once per file version, off the critical path.
    private static func storeThumbnail(_ image: CGImage, orientation: CGImagePropertyOrientation, key: FrameKey,
                                       into cache: DiskThumbnailCache) {
        Task.detached(priority: .background) {
            cache.store(image, orientation: orientation, path: key.url.path, size: key.fileSize,
                        modified: key.modified, longEdge: thumbnailEdge)
        }
    }

    /// Develops the RAW of `key` into a texture (V-02): the neutral filter, the render, the mip chain, then the
    /// histogram from a small mip level (the frame never exists as a `CGImage`). Checks for cancellation between
    /// the steps; a render already running cannot be stopped, so its result is dropped by the caller's cache.
    static func develop(_ key: FrameKey, minLongEdge: Int) throws -> LoadedFrame<LoupeFrame> {
        let token = Perf.begin(.rawDevelop)
        defer { Perf.end(token) }
        try Task.checkCancellation()
        guard let gpu = LoupeGPU.shared else { throw RawDevelopError.unsupported }
        let filter = try RawDeveloper.neutralFilter(for: key.url, minLongEdge: minLongEdge)
        try Task.checkCancellation()
        guard let output = filter.outputImage, let prepared = try gpu.prepare(developed: output) else {
            throw RawDevelopError.unsupported
        }
        var histogram: Histogram?
        if let small = Perf.measure(.histogram, { gpu.readback(prepared, maxEdge: 1024) }) {
            histogram = Histogram.compute(bgra: small.bgra, pixelCount: small.width * small.height, source: .raw)
        }
        let size = prepared.displaySize
        return LoadedFrame(frame: LoupeFrame(image: prepared, width: Int(size.width), height: Int(size.height), histogram: histogram),
                           cost: prepared.byteCost)
    }

    /// The disk thumbnail of `key` as a texture, or nil when there is none yet.
    static func placeholder(for key: FrameKey, thumbnails: DiskThumbnailCache) -> PreparedImage? {
        guard let thumb = thumbnails.thumbnail(path: key.url.path, size: key.fileSize, modified: key.modified,
                                               longEdge: thumbnailEdge),
              let gpu = LoupeGPU.shared
        else { return nil }
        return gpu.prepare(thumb.image, orientation: thumb.orientation)
    }
}
