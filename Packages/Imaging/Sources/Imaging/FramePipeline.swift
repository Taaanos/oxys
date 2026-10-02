import Diagnostics
import Foundation

/// What the pipeline loads: one file at one size and modification date, so an edited file is never served stale.
public struct FrameKey: Hashable, Sendable {
    public let url: URL
    public let fileSize: Int
    public let modified: Date
    public let isRaw: Bool

    public init(url: URL, fileSize: Int = 0, modified: Date, isRaw: Bool) {
        self.url = url
        self.fileSize = fileSize
        self.modified = modified
        self.isRaw = isRaw
    }
}

/// A loaded frame and what it costs in memory.
public struct LoadedFrame<Frame: Sendable>: Sendable {
    public let frame: Frame
    public let cost: Int

    public init(frame: Frame, cost: Int) {
        self.frame = frame
        self.cost = cost
    }
}

/// Loads frames for the newest target, prefetches its neighbors and keeps what it loaded under a byte budget
/// (M-04). It does not know what a frame is: `load` reads, decodes and uploads one file, and should call
/// `Task.checkCancellation()` between those steps, because the pipeline cancels any request that is no longer
/// the target or in the prefetch window as soon as a newer request arrives.
public actor FramePipeline<Frame: Sendable> {
    public typealias Loader = @Sendable (FrameKey) async throws -> LoadedFrame<Frame>

    private let load: Loader
    private var cache: ByteBudgetCache<FrameKey, Frame>
    private struct Inflight {
        let id: UInt64
        let task: Task<Result<LoadedFrame<Frame>, any Error>, Never>
    }

    private var inflight: [FrameKey: Inflight] = [:]
    private var nextID: UInt64 = 0
    private var prefetchDriver: Task<Void, Never>?
    private let maxPrefetchConcurrency: Int
    /// Smoothed load time in seconds; drives the "reads are slow" widening.
    private var averageLoad: Double = 0
    /// The budget the caller asked for. While frames load, each one needs working memory on top of its final
    /// cost (the decoded image, the upload buffer), so the cache gives that much up: the budget bounds the
    /// cache and the loads together, not the cache alone (M-26).
    private var requestedBudget: Int
    private let transientFactor: Double
    private var lastCost = 0

    public static var slowLoadThreshold: Double { 0.15 }

    /// `transientFactor`: working memory of one load, as a multiple of the finished frame's cost (0 = ignore).
    public init(budget: Int, maxPrefetchConcurrency: Int = 2, transientFactor: Double = 0, load: @escaping Loader) {
        cache = ByteBudgetCache(budget: budget)
        requestedBudget = budget
        self.transientFactor = transientFactor
        self.maxPrefetchConcurrency = maxPrefetchConcurrency
        self.load = load
    }

    public var isSlow: Bool { averageLoad > Self.slowLoadThreshold }
    public var cachedBytes: Int { cache.totalCost }

    public func setBudget(_ bytes: Int) {
        requestedBudget = bytes
        applyBudget()
    }

    /// The cache's share of the budget right now: what was asked for, less the working memory of the loads in
    /// flight, but never under half of it.
    private func applyBudget() {
        let reserve = Int(Double(inflight.count * lastCost) * transientFactor)
        cache.budget = max(requestedBudget - reserve, requestedBudget / 2)
    }

    public func isCached(_ key: FrameKey) -> Bool { cache.contains(key) }

    /// The frame if it is in the cache, with no loading and no change to what is in flight.
    public func cachedFrame(_ key: FrameKey) -> Frame? { cache.value(for: key) }

    /// The frame for `target`, loading it at once at high priority. `prefetch` lists the neighbors worth having
    /// next, most useful first. Anything in flight that is neither is cancelled before it reads or decodes.
    /// Returns nil when this request was itself superseded (cancelled) before it finished.
    public func frame(for target: FrameKey, prefetch: [FrameKey]) async throws -> Frame? {
        let wanted = Set([target] + prefetch)
        for (key, entry) in inflight where !wanted.contains(key) {
            entry.task.cancel()
            inflight[key] = nil
        }
        applyBudget()
        prefetchDriver?.cancel()
        prefetchDriver = nil

        let hit = cache.value(for: target)
        if let hit {
            startPrefetch(prefetch)
            return hit
        }
        let task = inflight[target]?.task ?? start(target, priority: .userInitiated)
        startPrefetch(prefetch)
        switch await task.value {
        case .success(let loaded): return loaded.frame
        case .failure(let error):
            if error is CancellationError { return nil }
            throw error
        }
    }

    /// Drops everything: a new folder was opened.
    public func reset() {
        for entry in inflight.values { entry.task.cancel() }
        inflight = [:]
        prefetchDriver?.cancel()
        prefetchDriver = nil
        cache.removeAll()
    }

    // MARK: private

    private func start(_ key: FrameKey, priority: TaskPriority) -> Task<Result<LoadedFrame<Frame>, any Error>, Never> {
        let load = load
        let started = ContinuousClock.now
        let task = Task(priority: priority) { () -> Result<LoadedFrame<Frame>, any Error> in
            do {
                try Task.checkCancellation()
                let token = Perf.begin(.frameLoad)
                defer { Perf.end(token) }
                return .success(try await load(key))
            } catch { return .failure(error) }
        }
        nextID += 1
        let id = nextID
        inflight[key] = Inflight(id: id, task: task)
        applyBudget()
        // Files the result in the cache when it lands, independent of whoever is waiting for it.
        Task {
            let result = await task.value
            self.finished(key, id: id, result: result, started: started)
        }
        return task
    }

    private func finished(_ key: FrameKey, id: UInt64, result: Result<LoadedFrame<Frame>, any Error>,
                          started: ContinuousClock.Instant) {
        // Only the request still registered may fill the cache; one cancelled and replaced must not.
        guard inflight[key]?.id == id else { return }
        inflight[key] = nil
        if case .success(let loaded) = result {
            lastCost = loaded.cost
            applyBudget()
            cache.insert(loaded.frame, cost: loaded.cost, for: key)
            let seconds = started.duration(to: .now).seconds
            averageLoad = averageLoad == 0 ? seconds : averageLoad * 0.7 + seconds * 0.3
        }
    }

    private func startPrefetch(_ keys: [FrameKey]) {
        let pending = keys.filter { !cache.contains($0) && inflight[$0] == nil }
        guard !pending.isEmpty else { return }
        let limit = maxPrefetchConcurrency
        prefetchDriver = Task(priority: .utility) { [pipeline = self] in
            var next = pending.makeIterator()
            await withTaskGroup(of: Void.self) { group in
                func launch() -> Bool {
                    guard let key = next.next() else { return false }
                    group.addTask { await pipeline.prefetchOne(key) }
                    return true
                }
                for _ in 0..<limit where launch() {}
                while await group.next() != nil {
                    if Task.isCancelled { group.cancelAll(); break }
                    _ = launch()
                }
            }
        }
    }

    private func prefetchOne(_ key: FrameKey) async {
        guard !Task.isCancelled, !cache.contains(key) else { return }
        let task = inflight[key]?.task ?? start(key, priority: .utility)
        _ = await task.value
    }
}

extension Duration {
    var seconds: Double { Double(components.seconds) + Double(components.attoseconds) / 1e18 }
}
