import Canvas
import Foundation
import Imaging
import Library

/// What the pipeline holds per photo: the uploaded texture and the size of the preview it came from.
nonisolated struct LoupeFrame: Sendable {
    let image: PreparedImage
    let width: Int
    let height: Int
}

/// The pipeline's work for one photo: map the file, decode the embedded preview, upload it. Checks for
/// cancellation between the steps, so a request that was superseded stops before the next expensive one.
nonisolated enum FrameLoader {
    /// Long edge of the disk thumbnails, which double as Loupe's stand-in while a full preview loads.
    static let thumbnailEdge = 512

    static func key(for photo: Photo) -> FrameKey {
        FrameKey(url: photo.url, fileSize: photo.fileSize, modified: photo.modificationDate, isRaw: photo.format.isRaw)
    }

    static func load(_ key: FrameKey, thumbnails: DiskThumbnailCache) throws -> LoadedFrame<LoupeFrame> {
        do {
            try Task.checkCancellation()
            let source = try PreviewSource.open(key.url, isRaw: key.isRaw)
            try Task.checkCancellation()
            let decoded = try source.decodeLoupe(maxPixelSize: 8192)
            try Task.checkCancellation()
            guard let gpu = LoupeGPU.shared, let prepared = gpu.prepare(decoded.image, orientation: decoded.orientation)
            else { throw PreviewError.corrupt }
            let size = decoded.sourceDisplaySize
            storeThumbnail(from: source, key: key, into: thumbnails)
            return LoadedFrame(frame: LoupeFrame(image: prepared, width: size.width, height: size.height),
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
    private static func storeThumbnail(from source: PreviewSource, key: FrameKey, into cache: DiskThumbnailCache) {
        Task.detached(priority: .background) {
            let file = cache.fileURL(path: key.url.path, size: key.fileSize, modified: key.modified, longEdge: thumbnailEdge)
            guard !FileManager.default.fileExists(atPath: file.path),
                  let grid = try? source.decodeGrid(longEdge: thumbnailEdge) else { return }
            cache.store(grid.image, orientation: grid.orientation, path: key.url.path, size: key.fileSize,
                        modified: key.modified, longEdge: thumbnailEdge)
        }
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
