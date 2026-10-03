import Diagnostics
import Foundation
import Synchronization

/// The developed RAWs held in memory (V-02): at most `maxCount` of them and `maxBytes` together, least recently
/// used out first (the newest always stays). Only one decode runs at a time; asking for another photo, or
/// `cancelInflight()`, cancels it, and a result that arrives after that is dropped, never cached or shown.
/// Like `FramePipeline` it does not know what a frame is: `load` decodes and uploads one file and should call
/// `Task.checkCancellation()` between the steps.
public final class RawFrameCache<Frame: Sendable>: Sendable {
    public typealias Loader = @Sendable (FrameKey) async throws -> LoadedFrame<Frame>

    private struct Entry {
        let frame: Frame
        let cost: Int
        var tick: UInt64
    }

    private struct Inflight {
        let key: FrameKey
        let id: UInt64
        let task: Task<LoadedFrame<Frame>, any Error>
    }

    private struct State {
        var entries: [FrameKey: Entry] = [:]
        var inflight: Inflight?
        var clock: UInt64 = 0
        var nextID: UInt64 = 0
        var maxCount: Int
        var maxBytes: Int
        /// Develops whose task has not ended: a cancelled one keeps its working memory until it returns (P-04).
        var running = 0
        var lastCost = 0
    }

    private let state: Mutex<State>
    private let budget: MemoryBudget?
    private let transientFactor: Double

    /// `budget`: the shared budget (P-04); the cache keeps no more than its share of it, besides `maxBytes`.
    /// `transientFactor`: the working memory of one develop (the decoder, the render target) as a multiple of the
    /// finished frame's cost; it counts against the shared budget while the develop runs.
    public init(maxCount: Int = 5, maxBytes: Int = .max, budget: MemoryBudget? = nil, transientFactor: Double = 0) {
        state = Mutex(State(maxCount: max(1, maxCount), maxBytes: maxBytes))
        self.budget = budget
        self.transientFactor = transientFactor
        budget?.register(.raw) { [weak self] in self?.shrinkToShare() }
    }

    private func shrinkToShare() {
        locked { evict(&$0) }
    }

    public var maxCount: Int { state.withLock { $0.maxCount } }
    public var maxBytes: Int { state.withLock { $0.maxBytes } }

    /// New limits (the settings changed). Frames over them go at once, least recently used first. The bytes limit
    /// is the higher one: a large count never keeps more than `maxBytes`.
    public func setLimits(maxCount: Int, maxBytes: Int) {
        locked { s in
            s.maxCount = max(1, maxCount)
            s.maxBytes = maxBytes
            evict(&s)
        }
    }

    public var count: Int { state.withLock { $0.entries.count } }
    public var totalCost: Int { state.withLock { $0.entries.values.reduce(0) { $0 + $1.cost } } }
    public var isDeveloping: Bool { state.withLock { $0.inflight != nil } }
    public func contains(_ key: FrameKey) -> Bool { state.withLock { $0.entries[key] != nil } }

    /// The developed frame for `key`, marked as most recently used.
    public func cached(_ key: FrameKey) -> Frame? {
        state.withLock { s in
            guard var entry = s.entries[key] else { return nil }
            s.clock += 1
            entry.tick = s.clock
            s.entries[key] = entry
            return entry.frame
        }
    }

    /// Develops `key` (or returns it from the cache). Nil when this request was cancelled before it finished.
    public func develop(_ key: FrameKey, load: @escaping Loader) async throws -> Frame? {
        if let hit = cached(key) { return hit }
        let (task, id) = locked { s -> (Task<LoadedFrame<Frame>, any Error>, UInt64) in
            if let running = s.inflight {
                if running.key == key { return (running.task, running.id) }
                running.task.cancel()
            }
            s.nextID += 1
            s.running += 1
            let task = Task(priority: .userInitiated) { [self] in
                defer { locked { $0.running -= 1 } }
                return try await load(key)
            }
            s.inflight = Inflight(key: key, id: s.nextID, task: task)
            return (task, s.nextID)
        }
        do {
            let loaded = try await task.value
            let kept = locked { s -> Bool in
                // Only the request still registered, and not cancelled, may fill the cache.
                guard s.inflight?.id == id else { return false }
                s.inflight = nil
                s.clock += 1
                s.lastCost = loaded.cost
                s.entries[key] = Entry(frame: loaded.frame, cost: loaded.cost, tick: s.clock)
                evict(&s)
                return true
            }
            if !kept { Perf.end(Perf.begin(.rawWasted)) }
            return kept ? loaded.frame : nil
        } catch {
            state.withLock { if $0.inflight?.id == id { $0.inflight = nil } }
            if error is CancellationError { return nil }
            throw error
        }
    }

    /// Moving on: the decode in flight, if any, stops at its next check and its result is dropped.
    public func cancelInflight() {
        state.withLock { s in
            s.inflight?.task.cancel()
            s.inflight = nil
        }
    }

    /// A new folder, or memory pressure: everything goes.
    public func removeAll() {
        locked { s in
            s.inflight?.task.cancel()
            s.inflight = nil
            s.entries.removeAll()
        }
    }

    /// Memory pressure (P-04): only the entry for `key` stays, if there is one.
    public func trim(keeping key: FrameKey?) {
        locked { s in
            s.entries = s.entries.filter { $0.key == key }
        }
    }

    private func evict(_ s: inout State) {
        func total() -> Int { s.entries.values.reduce(0) { $0 + $1.cost } }
        // What a develop in progress needs comes out of the share first (P-04); the newest entry stays regardless.
        let limit = min(s.maxBytes, (budget?.share(of: .raw) ?? .max) - transient(s))
        while s.entries.count > 1, s.entries.count > s.maxCount || total() > limit,
              let oldest = s.entries.min(by: { $0.value.tick < $1.value.tick })?.key {
            s.entries[oldest] = nil
        }
    }

    /// Runs `body` under the lock, then tells the shared budget what the cache uses now. The report goes out after
    /// the lock is released: the budget may call `shrinkToShare` back.
    @discardableResult
    private func locked<R>(_ body: (inout State) -> R) -> R {
        let (result, used) = state.withLock { s -> (R, Int) in
            let result = body(&s)
            let held = s.entries.values.reduce(0) { $0 + $1.cost }
            return (result, held + transient(s))
        }
        budget?.setUsed(.raw, used)
        return result
    }

    private func transient(_ s: State) -> Int { Int(Double(s.running * s.lastCost) * transientFactor) }
}
