import CoreGraphics
import Diagnostics
import Foundation
import Imaging

/// Loads Grid's thumbnails (M-12): from the disk cache when it has them, otherwise by decoding the file's
/// smallest adequate embedded preview and storing the result. The newest wish list decides what runs:
/// whatever is no longer on it is cancelled, and a handful of loads run at once so a fast scroll never
/// queues work for rows that went by.
@MainActor
final class GridThumbnailLoader {
    struct Key: Hashable, Sendable {
        let frame: FrameKey
        let edge: Int
    }

    private struct Loaded: @unchecked Sendable {
        let image: CGImage?
    }

    private var cache = ByteBudgetCache<Key, CGImage>(budget: 256 << 20)
    private var inflight: [Key: (id: UInt64, task: Task<Void, Never>)] = [:]
    private var failed: Set<Key> = []
    private var wanted: [Key] = []
    private var nextID: UInt64 = 0
    private let store: DiskThumbnailCache
    private let concurrency: Int

    /// Called on the main actor each time a thumbnail becomes available (or is known to be impossible).
    var onResolved: ((Key) -> Void)?

    init(store: DiskThumbnailCache, concurrency: Int = 4) {
        self.store = store
        self.concurrency = concurrency
    }

    func image(for key: Key) -> CGImage? { cache.value(for: key) }
    func isFailed(_ key: Key) -> Bool { failed.contains(key) }
    func isResolved(_ key: Key) -> Bool { cache.contains(key) || failed.contains(key) }

    /// Replaces the wish list, most wanted first.
    func want(_ keys: [Key]) {
        wanted = keys
        let set = Set(keys)
        for (key, entry) in inflight where !set.contains(key) {
            entry.task.cancel()
            inflight[key] = nil
        }
        pump()
    }

    /// A new folder: forget everything.
    func reset() {
        for entry in inflight.values { entry.task.cancel() }
        inflight = [:]
        wanted = []
        failed = []
        cache.removeAll()
    }

    private func pump() {
        for key in wanted {
            if inflight.count >= concurrency { break }
            if cache.contains(key) || failed.contains(key) || inflight[key] != nil { continue }
            start(key)
        }
    }

    private func start(_ key: Key) {
        nextID += 1
        let id = nextID
        let store = store
        let task = Task.detached(priority: .userInitiated) { [weak self] in
            let loaded = Self.load(key, store: store)
            guard !Task.isCancelled else { return }
            await self?.finished(key, id: id, loaded: loaded)
        }
        inflight[key] = (id, task)
    }

    private func finished(_ key: Key, id: UInt64, loaded: Loaded) {
        // Only the request still registered may fill the cache; one cancelled and replaced must not.
        guard inflight[key]?.id == id else { return }
        inflight[key] = nil
        if let image = loaded.image {
            cache.insert(image, cost: image.width * image.height * 4, for: key)
        } else {
            failed.insert(key)
        }
        onResolved?(key)
        pump()
    }

    private nonisolated static func load(_ key: Key, store: DiskThumbnailCache) -> Loaded {
        let token = Perf.begin(.gridThumbnail)
        defer { Perf.end(token) }
        let f = key.frame
        if let hit = store.thumbnail(path: f.url.path, size: f.fileSize, modified: f.modified, longEdge: key.edge) {
            return Loaded(image: hit.image.upright(hit.orientation))
        }
        guard !Task.isCancelled, let source = try? PreviewSource.open(f.url, isRaw: f.isRaw),
              !Task.isCancelled, let decoded = try? source.decodeGrid(longEdge: key.edge)
        else { return Loaded(image: nil) }
        store.store(decoded.image, orientation: decoded.orientation, path: f.url.path, size: f.fileSize,
                    modified: f.modified, longEdge: key.edge)
        return Loaded(image: decoded.image.upright(decoded.orientation))
    }
}
