import Diagnostics
import Foundation
import Darwin.malloc

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

    /// A frame that is fast to make and is not kept (P-03): nil when the file has no quick form.
    public typealias QuickLoader = @Sendable (FrameKey) async throws -> Frame?

    private let load: Loader
    private let quick: QuickLoader?
    private var quickTask: Task<Frame?, any Error>?
    /// Screen-size loads whose task has not ended: a cancelled one finishes its decode first, so it still holds memory.
    private var quickRunning = 0
    private var cache: ByteBudgetCache<FrameKey, Frame>
    private struct Inflight {
        let id: UInt64
        let task: Task<Result<LoadedFrame<Frame>, any Error>, Never>
    }

    private var inflight: [FrameKey: Inflight] = [:]
    /// Loads whose task has not ended. A cancelled load leaves `inflight` at once but keeps its memory until it
    /// really returns (P-02), so the reservation counts these, not `inflight`.
    private(set) var running = 0
    private var nextID: UInt64 = 0
    private var prefetchDriver: Task<Void, Never>?
    private let maxPrefetchConcurrency: Int
    /// Smoothed load time in seconds; drives the "reads are slow" widening.
    private var averageLoad: Double = 0
    /// The budget the caller asked for. While frames load, each one needs working memory on top of its final
    /// cost (the decoded image, the upload buffer), so the cache gives that much up: the budget bounds the
    /// cache and the loads together, not the cache alone (M-26).
    private let memory: MemoryBudget
    private let transientFactor: Double
    private var lastCost = 0
    /// P-04: the prefetch waits this long after a request, so a held key loads its target only and the window
    /// loads once the key is up. Zero starts it at once.
    private let prefetchHold: Duration
    private var pendingPrefetch: Task<Void, Never>?
    private var lastTarget: FrameKey?
    private var lastWindow: [FrameKey] = []
    private var pressure = MemoryPressure.normal
    /// P-04: `malloc_zone_pressure_relief` after the pipeline has been idle this long (nil: never).
    private let reliefAfter: Duration?
    private var reliefTask: Task<Void, Never>?

    public static var slowLoadThreshold: Double { 0.15 }

    /// `transientFactor`: working memory of one load, as a multiple of the finished frame's cost (0 = ignore).
    public init(budget: Int, memory: MemoryBudget? = nil, maxPrefetchConcurrency: Int = 2, transientFactor: Double = 0,
                prefetchHold: Duration = .zero, reliefAfter: Duration? = nil, quick: QuickLoader? = nil,
                load: @escaping Loader) {
        self.quick = quick
        cache = ByteBudgetCache(budget: budget)
        self.memory = memory ?? MemoryBudget(total: budget)
        self.memory.setTotal(budget)
        self.prefetchHold = prefetchHold
        self.reliefAfter = reliefAfter
        self.transientFactor = transientFactor
        self.maxPrefetchConcurrency = maxPrefetchConcurrency
        self.load = load
        self.memory.register(.frames) { [weak self] in
            guard let self else { return }
            Task { await self.applyBudget() }
        }
    }

    public var isSlow: Bool { averageLoad > Self.slowLoadThreshold }
    public var cachedBytes: Int { cache.totalCost }
    /// No load is running or waiting, so the pipeline will not wake the CPU until the next request (P-09).
    public var isIdle: Bool { running == 0 && inflight.isEmpty }
    /// What the cache may hold right now (for tests): the budget less the reservation of running loads.
    var budgetForCache: Int { cache.budget }

    public func setBudget(_ bytes: Int) {
        memory.setTotal(bytes)
        applyBudget()
    }

    /// The cache's share of the budget right now: what the shared budget leaves after the developed RAWs, less the
    /// working memory of the loads that still run (cancelled ones included, until they end), but never under the floor
    /// (a quarter of the total).
    private func applyBudget() {
        // A screen-size frame in the making holds a fraction of a full frame's pixels; count it as half a load.
        let loads = Double(running) + 0.5 * Double(quickRunning)
        let reserve = Int(loads * Double(lastCost) * transientFactor)
        cache.budget = max(memory.share(of: .frames) - reserve, memory.floor)
        memory.setUsed(.frames, cache.totalCost)
    }

    /// Memory pressure (P-04). On a warning the cache keeps the frame on screen and 2 of its neighbors, on critical
    /// the frame on screen only, and the prefetch window shrinks the same way until the pressure ends.
    public func setPressure(_ level: MemoryPressure) {
        pressure = level
        guard level != .normal else { return }
        let keep = Set(([lastTarget].compactMap { $0 }) + lastWindow.prefix(level.neighborsKept))
        cancelLoads(except: keep)
        cache.retain(keep)
        applyBudget()
    }

    public func isCached(_ key: FrameKey) -> Bool { cache.contains(key) }

    /// The frame if it is in the cache, with no loading and no change to what is in flight.
    public func cachedFrame(_ key: FrameKey) -> Frame? { cache.value(for: key) }

    /// P-03: a quick frame of `target` for a photo that is not here yet, so the screen is not empty while the full
    /// frame loads. It is not cached. Nil when there is nothing quick to show: no quick loader, the file has no quick
    /// form, `target` is cached or already loading (waiting for that is cheaper), a newer request came, or the load
    /// failed (the full load reports the error). A cold arrival means the user is moving, so every other load and
    /// the prefetch stop first and leave the CPU to this one.
    public func quickFrame(for target: FrameKey) async -> Frame? {
        guard let quick, !cache.contains(target), inflight[target] == nil else { return nil }
        cancelLoads(except: [target])
        quickTask?.cancel()
        quickRunning += 1
        let task = Task(priority: .high) { [pipeline = self] in
            defer { Task { await pipeline.quickEnded() } }
            return try await quick(target)
        }
        quickTask = task
        applyBudget()
        return try? await task.value
    }

    private func quickEnded() {
        quickRunning -= 1
        applyBudget()
    }

    /// The frame for `target`, loading it at once at high priority. `prefetch` lists the neighbors worth having
    /// next, most useful first. Anything in flight that is neither is cancelled before it reads or decodes.
    /// Returns nil when this request was itself superseded (cancelled) before it finished.
    public func frame(for target: FrameKey, prefetch: [FrameKey]) async throws -> Frame? {
        cancelLoads(except: Set([target] + prefetch))
        lastTarget = target
        lastWindow = prefetch
        reliefTask?.cancel()

        let hit = cache.value(for: target)
        if let hit {
            schedulePrefetch()
            return hit
        }
        let task = inflight[target]?.task ?? start(target, priority: .userInitiated)
        schedulePrefetch()
        switch await task.value {
        case .success(let loaded): return loaded.frame
        case .failure(let error):
            if error is CancellationError { return nil }
            throw error
        }
    }

    private func cancelLoads(except wanted: Set<FrameKey>) {
        for (key, entry) in inflight where !wanted.contains(key) {
            entry.task.cancel()
            inflight[key] = nil
        }
        applyBudget()
        prefetchDriver?.cancel()
        prefetchDriver = nil
        pendingPrefetch?.cancel()
        pendingPrefetch = nil
    }

    /// Drops everything: a new folder was opened.
    public func reset() {
        quickTask?.cancel()
        quickTask = nil
        for entry in inflight.values { entry.task.cancel() }
        inflight = [:]
        prefetchDriver?.cancel()
        prefetchDriver = nil
        pendingPrefetch?.cancel()
        pendingPrefetch = nil
        reliefTask?.cancel()
        lastTarget = nil
        lastWindow = []
        cache.removeAll()
        applyBudget()
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
        running += 1
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
        running -= 1
        defer { scheduleRelief() }
        // Only the request still registered may fill the cache; one cancelled and replaced must not.
        guard inflight[key]?.id == id else { applyBudget(); return }
        inflight[key] = nil
        if case .success(let loaded) = result {
            lastCost = loaded.cost
            applyBudget()
            cache.insert(loaded.frame, cost: loaded.cost, for: key)
            memory.setUsed(.frames, cache.totalCost)
            let seconds = started.duration(to: .now).seconds
            averageLoad = averageLoad == 0 ? seconds : averageLoad * 0.7 + seconds * 0.3
        }
    }

    /// Starts the prefetch for the last request: at once, or when `prefetchHold` has passed with no newer request.
    private func schedulePrefetch() {
        pendingPrefetch?.cancel()
        pendingPrefetch = nil
        let window = Array(lastWindow.prefix(pressure.prefetchLimit))
        guard prefetchHold > .zero else { startPrefetch(window); return }
        let hold = prefetchHold
        pendingPrefetch = Task { [pipeline = self] in
            try? await Task.sleep(for: hold)
            guard !Task.isCancelled else { return }
            await pipeline.startHeldPrefetch()
        }
    }

    private func startHeldPrefetch() {
        pendingPrefetch = nil
        startPrefetch(Array(lastWindow.prefix(pressure.prefetchLimit)))
    }

    /// After a scrub the allocator keeps pages it freed; give them back once nothing has run for `reliefAfter`.
    private func scheduleRelief() {
        guard let delay = reliefAfter, isIdle, pendingPrefetch == nil else { return }
        reliefTask?.cancel()
        reliefTask = Task { [pipeline = self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, await pipeline.canRelieve else { return }
            await pipeline.relieveNow()
        }
    }

    private func relieveNow() {
        let token = Perf.begin(.memoryRelief)
        malloc_zone_pressure_relief(nil, 0)
        Perf.end(token)
    }

    private var canRelieve: Bool { isIdle && pendingPrefetch == nil }

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
        scheduleRelief()
    }
}

/// How short of memory the system says it is (P-04).
public enum MemoryPressure: Sendable, Equatable {
    case normal, warning, critical

    /// How many neighbors of the frame on screen stay in the cache.
    var neighborsKept: Int { self == .warning ? 2 : 0 }
    /// How many frames of the prefetch window may load.
    var prefetchLimit: Int {
        switch self {
        case .normal: .max
        case .warning: 2
        case .critical: 0
        }
    }
}

extension Duration {
    var seconds: Double { Double(components.seconds) + Double(components.attoseconds) / 1e18 }
}
