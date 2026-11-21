import CoreGraphics
import Foundation
import ImageIO
import Synchronization
import Testing
@testable import Imaging

// MARK: - Deterministic PRNG (SplitMix64)

private struct SeededRNG {
    private var state: UInt64

    init(seed: UInt64) { self.state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    mutating func int(in range: ClosedRange<Int>) -> Int {
        let span = UInt64(range.upperBound - range.lowerBound) + 1
        return range.lowerBound + Int(next() % span)
    }

    mutating func bool(probability num: Int = 1, outOf den: Int = 2) -> Bool {
        Int(next() % UInt64(den)) < num
    }

    mutating func pick<T>(_ items: [T]) -> T {
        items[Int(next() % UInt64(items.count))]
    }
}

private func hex(_ seed: UInt64) -> String { "0x" + String(seed, radix: 16, uppercase: true) }

// MARK: - Suite 1: ByteBudgetCache Differential Oracle (100% Deterministic by Seed)

@Suite struct ByteBudgetCacheDifferentialTests {
    /// Dead-simple array-backed LRU oracle (most recent at the end).
    private struct LRUOracle {
        struct Item { var key: Int; var value: Int; var cost: Int }
        var items: [Item] = []
        var budget: Int { didSet { evict() } }

        var count: Int { items.count }
        var totalCost: Int { items.reduce(0) { $0 + $1.cost } }

        func contains(_ key: Int) -> Bool { items.contains { $0.key == key } }

        mutating func value(for key: Int) -> Int? {
            guard let i = items.firstIndex(where: { $0.key == key }) else { return nil }
            let item = items.remove(at: i)
            items.append(item)
            return item.value
        }

        mutating func insert(_ value: Int, cost: Int, for key: Int) {
            remove(key)
            guard cost <= budget else { return }
            items.append(Item(key: key, value: value, cost: cost))
            evict()
        }

        mutating func remove(_ key: Int) {
            items.removeAll { $0.key == key }
        }

        mutating func removeAll() {
            items.removeAll()
        }

        mutating func retain(_ keys: Set<Int>) {
            items.removeAll { !keys.contains($0.key) }
        }

        private mutating func evict() {
            while totalCost > budget, !items.isEmpty {
                items.removeFirst()
            }
        }
    }

    @Test(arguments: [UInt64(0xC001), 0xC002, 0xC003, 0xC004, 0xC005, 0xC006])
    func cacheMatchesOracleAcrossRandomizedOps(seed: UInt64) {
        var rng = SeededRNG(seed: seed)
        let initialBudget = rng.int(in: 20...120)
        var cache = ByteBudgetCache<Int, Int>(budget: initialBudget)
        var oracle = LRUOracle(budget: initialBudget)
        let keySpace = 0...25

        for step in 0..<2000 {
            switch rng.int(in: 0...9) {
            case 0...3:
                let k = rng.int(in: keySpace)
                let v = rng.int(in: 0...10_000)
                let cost = rng.int(in: 0...140) // Includes 0-cost and oversized (> budget) entries.
                cache.insert(v, cost: cost, for: k)
                oracle.insert(v, cost: cost, for: k)
            case 4...5:
                let k = rng.int(in: keySpace)
                let got = cache.value(for: k)
                let want = oracle.value(for: k)
                #expect(got == want, "seed=\(hex(seed)) step=\(step) value(\(k)): got=\(String(describing: got)) want=\(String(describing: want))")
            case 6:
                let k = rng.int(in: keySpace)
                cache.remove(k)
                oracle.remove(k)
            case 7:
                let newBudget = rng.int(in: 0...150)
                cache.budget = newBudget
                oracle.budget = newBudget
            case 8:
                var keep: Set<Int> = []
                for _ in 0..<rng.int(in: 0...8) { keep.insert(rng.int(in: keySpace)) }
                cache.retain(keep)
                oracle.retain(keep)
            default:
                cache.removeAll()
                oracle.removeAll()
            }

            #expect(cache.count == oracle.count, "seed=\(hex(seed)) step=\(step): count mismatch")
            #expect(cache.totalCost == oracle.totalCost, "seed=\(hex(seed)) step=\(step): totalCost mismatch")
            #expect(cache.totalCost <= cache.budget, "seed=\(hex(seed)) step=\(step): exceeded budget")

            // Periodically verify exact membership across the entire key space.
            if step % 10 == 0 {
                for k in keySpace {
                    #expect(cache.contains(k) == oracle.contains(k),
                            "seed=\(hex(seed)) step=\(step): contains(\(k)) mismatch")
                }
            }
        }
    }
}

// MARK: - Suite 2: MemoryBudget Property Tests (100% Deterministic by Seed)

@Suite struct MemoryBudgetPropertyTests {
    @Test(arguments: [UInt64(0xB001), 0xB002, 0xB003, 0xB004])
    func sharedBudgetEnforcesFloorsAndShrinks(seed: UInt64) {
        var rng = SeededRNG(seed: seed)
        let budget = MemoryBudget(total: 400)
        let framesUsed = Mutex(0)
        let rawUsed = Mutex(0)
        let overlaysUsed = Mutex(0)
        let shrinkCalls = Mutex(0)

        budget.register(.frames) {
            shrinkCalls.withLock { $0 += 1 }
            let target = budget.share(of: .frames)
            let clamped = framesUsed.withLock { u -> Int in
                u = min(u, target)
                return u
            }
            budget.setUsed(.frames, clamped)
        }
        budget.register(.raw) {
            shrinkCalls.withLock { $0 += 1 }
            let target = budget.share(of: .raw)
            let clamped = rawUsed.withLock { u -> Int in
                u = min(u, target)
                return u
            }
            budget.setUsed(.raw, clamped)
        }

        for step in 0..<500 {
            switch rng.int(in: 0...3) {
            case 0:
                let total = rng.int(in: 100...1000)
                budget.setTotal(total)
            case 1:
                let v = rng.int(in: 0...600)
                framesUsed.withLock { $0 = v }
                budget.setUsed(.frames, v)
            case 2:
                let v = rng.int(in: 0...600)
                rawUsed.withLock { $0 = v }
                budget.setUsed(.raw, v)
            default:
                let v = rng.int(in: 0...200)
                overlaysUsed.withLock { $0 = v }
                budget.setUsed(.overlays, v)
            }

            let f = framesUsed.withLock { $0 }
            let r = rawUsed.withLock { $0 }
            let o = overlaysUsed.withLock { $0 }
            #expect(budget.used == f + r + o, "seed=\(hex(seed)) step=\(step): used accounting mismatch")
            #expect(budget.floor == budget.total / 4, "seed=\(hex(seed)) step=\(step): floor mismatch")
            #expect(budget.share(of: .frames) >= budget.floor, "seed=\(hex(seed)) step=\(step): frames share below floor")
            #expect(budget.share(of: .raw) >= budget.floor, "seed=\(hex(seed)) step=\(step): raw share below floor")
        }

        #expect(shrinkCalls.withLock { $0 } > 0, "seed=\(hex(seed)): expected budget pressure to trigger shrinks")
    }
}

// MARK: - Suite 3: Continuation-Gated FramePipeline Simulation

private struct SimulatedLoadError: Error, Equatable { let keyID: Int }

private func frameKey(_ id: Int) -> FrameKey {
    FrameKey(url: URL(fileURLWithPath: "/sim/\(id).arw"), fileSize: 1000 + id,
             modified: Date(timeIntervalSince1970: 1_800_000_000), isRaw: true)
}

private func frameID(_ key: FrameKey) -> Int {
    Int(key.url.deletingPathExtension().lastPathComponent)!
}

/// Controls every in-flight `load` and `quick` call via `CheckedContinuation`, letting the simulation driver
/// release completions, failures, and cancellations in exact seeded order without `Task.sleep`.
private final class GatedLoader: Sendable {
    enum Resolution: Sendable {
        case succeed(LoadedFrame<Int>)
        case fail(any Error)
    }

    struct PendingInfo: Sendable {
        let id: UInt64
        let key: FrameKey
        let isQuick: Bool
    }

    private struct Entry {
        let key: FrameKey
        let isQuick: Bool
        var continuation: CheckedContinuation<LoadedFrame<Int>, any Error>?
        var earlyResolution: Resolution?
    }

    private struct State {
        var nextID: UInt64 = 0
        var entries: [UInt64: Entry] = [:]
        var startedCount = 0
        var cancelledCount = 0
    }

    private let state = Mutex(State())

    func load(_ key: FrameKey, isQuick: Bool) async throws -> LoadedFrame<Int> {
        let id = state.withLock { s -> UInt64 in
            s.nextID += 1
            s.startedCount += 1
            s.entries[s.nextID] = Entry(key: key, isQuick: isQuick)
            return s.nextID
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { cont in
                let early: Resolution? = state.withLock { s in
                    guard var entry = s.entries[id] else { return .fail(CancellationError()) }
                    if let res = entry.earlyResolution {
                        s.entries.removeValue(forKey: id)
                        return res
                    }
                    entry.continuation = cont
                    s.entries[id] = entry
                    return nil
                }
                if let early { resume(cont, with: early) }
            }
        } onCancel: {
            let cont: CheckedContinuation<LoadedFrame<Int>, any Error>? = state.withLock { s in
                s.cancelledCount += 1
                guard var entry = s.entries[id] else { return nil }
                if let c = entry.continuation {
                    s.entries.removeValue(forKey: id)
                    return c
                }
                entry.earlyResolution = .fail(CancellationError())
                s.entries[id] = entry
                return nil
            }
            if let cont { cont.resume(throwing: CancellationError()) }
        }
    }

    /// Snapshot of currently suspended loads, sorted by allocation ID for deterministic seeded selection.
    func pending() -> [PendingInfo] {
        state.withLock { s in
            s.entries
                .compactMap { id, e in e.continuation != nil ? PendingInfo(id: id, key: e.key, isQuick: e.isQuick) : nil }
                .sorted { $0.id < $1.id }
        }
    }

    var totalPending: Int { state.withLock { $0.entries.count } }
    var startedCount: Int { state.withLock { $0.startedCount } }
    var cancelledCount: Int { state.withLock { $0.cancelledCount } }

    func release(id: UInt64, with resolution: Resolution) {
        let cont: CheckedContinuation<LoadedFrame<Int>, any Error>? = state.withLock { s in
            guard var entry = s.entries[id] else { return nil }
            if let c = entry.continuation {
                s.entries.removeValue(forKey: id)
                return c
            }
            entry.earlyResolution = resolution
            s.entries[id] = entry
            return nil
        }
        if let cont { resume(cont, with: resolution) }
    }

    func releaseAll(defaultCost: Int) {
        let toResume: [(CheckedContinuation<LoadedFrame<Int>, any Error>, FrameKey)] = state.withLock { s in
            var list: [(CheckedContinuation<LoadedFrame<Int>, any Error>, FrameKey)] = []
            for (id, entry) in s.entries {
                if let c = entry.continuation {
                    list.append((c, entry.key))
                    s.entries.removeValue(forKey: id)
                } else {
                    var updated = entry
                    updated.earlyResolution = .succeed(LoadedFrame(frame: frameID(entry.key), cost: defaultCost))
                    s.entries[id] = updated
                }
            }
            return list
        }
        for (cont, key) in toResume {
            cont.resume(returning: LoadedFrame(frame: frameID(key), cost: defaultCost))
        }
    }

    private func resume(_ cont: CheckedContinuation<LoadedFrame<Int>, any Error>, with resolution: Resolution) {
        switch resolution {
        case .succeed(let frame): cont.resume(returning: frame)
        case .fail(let error): cont.resume(throwing: error)
        }
    }
}

@Suite struct FramePipelineSimulationTests {
    @Test(arguments: [UInt64(0x1111), 0x2222, 0x3333, 0x4444, 0x5555, 0x6666])
    func gatedSimulationPreservesCorrectnessBudgetAndIdleness(seed: UInt64) async {
        var rng = SeededRNG(seed: seed)
        let gate = GatedLoader()
        let memory = MemoryBudget(total: 400)
        let pipeline = FramePipeline<Int>(
            budget: 400,
            memory: memory,
            maxPrefetchConcurrency: 2,
            transientFactor: 0.5,
            prefetchHold: .zero,
            reliefAfter: nil,
            quick: { key in
                try await gate.load(key, isQuick: true).frame
            },
            load: { key in
                try await gate.load(key, isQuick: false)
            }
        )

        var activeRequests: [(target: Int, task: Task<Result<Int?, any Error>, Never>)] = []
        var activeQuicks: [(target: Int, task: Task<Int?, Never>)] = []
        let photoCount = 30
        var cursor = rng.int(in: 0...(photoCount - 1))

        for step in 0..<120 {
            let op = rng.int(in: 0...11)
            switch op {
            case 0...3:
                // Navigate to a new photo (scrub forward/backward or random jump) with a prefetch window.
                let delta = rng.pick([-3, -1, 1, 1, 2, rng.int(in: -10...10)])
                cursor = min(max(cursor + delta, 0), photoCount - 1)
                let target = cursor
                let key = frameKey(target)
                let wasCached = await pipeline.isCached(key)
                let prevStarted = gate.startedCount
                let window = (1...3).compactMap { offset -> FrameKey? in
                    let idx = target + (delta >= 0 ? offset : -offset)
                    return (0..<photoCount).contains(idx) ? frameKey(idx) : nil
                }
                let task = Task<Result<Int?, any Error>, Never> {
                    do { return .success(try await pipeline.frame(for: key, prefetch: window)) }
                    catch { return .failure(error) }
                }
                activeRequests.append((target, task))
                // Let a cold request actually reach the gate so subsequent steps exercise real in-flight
                // cancellations, budget reservations, and out-of-order completions.
                if !wasCached {
                    for _ in 0..<50 where gate.startedCount == prevStarted {
                        try? await Task.sleep(for: .microseconds(200))
                    }
                }

            case 4:
                // Request a quick frame for the current cursor.
                let target = cursor
                let task = Task<Int?, Never> {
                    await pipeline.quickFrame(for: frameKey(target))
                }
                activeQuicks.append((target, task))
                await Task.yield()

            case 5...8:
                // Release one suspended load in seeded order (either succeeding with variable cost or failing).
                let pending = gate.pending()
                if !pending.isEmpty {
                    let chosen = rng.pick(pending)
                    let idNum = frameID(chosen.key)
                    if rng.bool(probability: 1, outOf: 6) {
                        gate.release(id: chosen.id, with: .fail(SimulatedLoadError(keyID: idNum)))
                    } else {
                        let cost = rng.int(in: 20...90)
                        gate.release(id: chosen.id, with: .succeed(LoadedFrame(frame: idNum, cost: cost)))
                    }
                }

            case 9:
                // Memory pressure spike or recovery.
                let level: MemoryPressure = rng.pick([.normal, .warning, .critical])
                await pipeline.setPressure(level)
                if level == .critical {
                    // Under critical pressure, at most 1 frame (lastTarget) stays cached.
                    let cached = await pipeline.cachedBytes
                    let budget = await pipeline.budgetForCache
                    #expect(cached <= budget, "seed=\(hex(seed)) step=\(step): exceeded budget under critical pressure")
                }

            case 10:
                // Dynamic budget change + competing RAW/overlay memory usage.
                let newTotal = rng.int(in: 200...800)
                await pipeline.setBudget(newTotal)
                memory.setUsed(.raw, rng.int(in: 0...(newTotal / 2)))
                memory.setUsed(.overlays, rng.int(in: 0...(newTotal / 8)))

            default:
                // Reset (simulates opening a new folder mid-scrub).
                await pipeline.reset()
                #expect(await pipeline.cachedBytes == 0,
                        "seed=\(hex(seed)) step=\(step): cache not empty immediately after reset()")
            }

            // Continuous budget invariant: cache never exceeds its assigned budget.
            let cachedBytes = await pipeline.cachedBytes
            let cacheBudget = await pipeline.budgetForCache
            #expect(cachedBytes <= cacheBudget,
                    "seed=\(hex(seed)) step=\(step): cachedBytes=\(cachedBytes) > budgetForCache=\(cacheBudget)")
        }

        // Drain all remaining loads and requests to verify eventual quiescence & correctness.
        for _ in 0..<200 {
            gate.releaseAll(defaultCost: 40)
            await Task.yield()
            if await pipeline.isIdle && gate.totalPending == 0 { break }
            try? await Task.sleep(for: .milliseconds(2))
        }

        // Verify every frame() result was either nil (superseded), the EXACT requested frame, or its own simulated error.
        for (target, task) in activeRequests {
            let result = await task.value
            switch result {
            case .success(let frame):
                if let frame {
                    #expect(frame == target,
                            "seed=\(hex(seed)): frame(for: \(target)) returned wrong frame \(frame)!")
                }
            case .failure(let error):
                #expect(error as? SimulatedLoadError == SimulatedLoadError(keyID: target),
                        "seed=\(hex(seed)): unexpected error \(error) for target \(target)")
            }
        }

        // Verify every quickFrame() result was either nil or the EXACT requested frame.
        for (target, task) in activeQuicks {
            if let quick = await task.value {
                #expect(quick == target,
                        "seed=\(hex(seed)): quickFrame(for: \(target)) returned wrong frame \(quick)!")
            }
        }

        // Drain any trailing prefetch spawned right before the last request completed.
        for _ in 0..<200 {
            gate.releaseAll(defaultCost: 40)
            if await pipeline.isIdle && gate.totalPending == 0 { break }
            try? await Task.sleep(for: .milliseconds(2))
        }

        #expect(await pipeline.isIdle, "seed=\(hex(seed)): pipeline did not settle to idle (P-09)")
        #expect(gate.totalPending == 0, "seed=\(hex(seed)): leaked pending continuations in loader")
        #expect(await pipeline.cachedBytes <= (await pipeline.budgetForCache),
                "seed=\(hex(seed)): final cachedBytes exceeds cache budget")
        #expect(gate.startedCount > 0, "seed=\(hex(seed)): simulation exercised no loads")
    }
}

// MARK: - Suite 4: PrefetchPlan Property Tests

@Suite struct PrefetchPlanPropertyTests {
    @Test(arguments: [UInt64(0x7101), 0x7102, 0x7103, 0x7104, 0x7105, 0x7106])
    func prefetchPlanObeysBoundsUniquenessAndDirectionBias(seed: UInt64) {
        var rng = SeededRNG(seed: seed)
        let plan = PrefetchPlan()

        for step in 0..<300 {
            let count = rng.int(in: 0...500)
            let current = count == 0 ? 0 : rng.int(in: 0...(count - 1))
            let dir: PrefetchPlan.Direction = rng.bool() ? .forward : .backward
            let slow = rng.bool()

            let indices = plan.indices(current: current, count: count, direction: dir, slow: slow)

            // 1. All indices strictly in 0..<count, never includes current, and zero duplicates.
            #expect(Set(indices).count == indices.count,
                    "seed=\(hex(seed)) step=\(step): duplicate indices in prefetch plan")
            for idx in indices {
                #expect(idx >= 0 && idx < count && idx != current,
                        "seed=\(hex(seed)) step=\(step): invalid index \(idx) for current=\(current) count=\(count)")
            }

            // 2. First prefetched index is the immediate neighbor in travel direction when it exists.
            let immediate = dir == .forward ? current + 1 : current - 1
            if (0..<count).contains(immediate) {
                #expect(indices.first == immediate,
                        "seed=\(hex(seed)) step=\(step): first prefetch \(String(describing: indices.first)) != immediate \(immediate)")
            }

            // 3. Slow mode never prefetches fewer frames than normal mode.
            let normal = plan.indices(current: current, count: count, direction: dir, slow: false)
            let wide = plan.indices(current: current, count: count, direction: dir, slow: true)
            #expect(wide.count >= normal.count,
                    "seed=\(hex(seed)) step=\(step): slow mode shrank prefetch window")
        }
    }
}

// MARK: - Suite 5: DiskThumbnailCache Fault Injection & Cap Tests

@Suite struct DiskThumbnailCacheFaultTests {
    private func makeTestImage(width: Int, height: Int, shade: UInt8) throws -> CGImage {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        var pixels = [UInt8](repeating: shade, count: width * height * 4)
        let ctx = try #require(CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8,
                                         bytesPerRow: width * 4, space: colorSpace,
                                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        return try #require(ctx.makeImage())
    }

    @Test(arguments: [UInt64(0x7201), 0x7202, 0x7203, 0x7204])
    func diskCacheSurvivesCorruptionAndEnforcesByteCap(seed: UInt64) throws {
        var rng = SeededRNG(seed: seed)
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("oxys-thumb-dst-\(hex(seed))-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: dir) }

        let cap = 25_000
        let cache = DiskThumbnailCache(directory: dir, byteCap: cap)
        let orientations: [CGImagePropertyOrientation] = [.up, .right, .down, .left, .upMirrored]
        let variants = ["", "strip"]
        let baseDate = Date(timeIntervalSince1970: 1_800_000_000)

        for step in 0..<25 {
            let photoID = rng.int(in: 0...11)
            let path = "/photos/IMG_\(photoID).ARW"
            let size = 10_000 + photoID
            let modified = baseDate.addingTimeInterval(Double(photoID))
            let variant = rng.pick(variants)
            let orient = rng.pick(orientations)

            switch rng.int(in: 0...3) {
            case 0...1:
                // Store a fresh thumbnail and verify immediate hit + orientation round-trip.
                let img = try makeTestImage(width: 64, height: 48, shade: UInt8(rng.int(in: 20...230)))
                cache.store(img, orientation: orient, path: path, size: size, modified: modified,
                            longEdge: 160, variant: variant)
                let hit = try #require(cache.thumbnail(path: path, size: size, modified: modified,
                                                       longEdge: 160, variant: variant),
                                       "seed=\(hex(seed)) step=\(step): immediate cache miss after store")
                #expect(hit.orientation == orient,
                        "seed=\(hex(seed)) step=\(step): orientation mismatch after store")
                // Changed size or modified date must miss!
                #expect(cache.thumbnail(path: path, size: size + 1, modified: modified,
                                        longEdge: 160, variant: variant) == nil)
                #expect(cache.thumbnail(path: path, size: size, modified: modified.addingTimeInterval(1),
                                        longEdge: 160, variant: variant) == nil)

            case 2:
                // Corrupt a cached thumbnail file on disk -> thumbnail() must return nil without trapping.
                let file = cache.fileURL(path: path, size: size, modified: modified, longEdge: 160, variant: variant)
                try fm.createDirectory(at: dir, withIntermediateDirectories: true)
                let garbage = Data((0..<rng.int(in: 0...128)).map { _ in UInt8(rng.int(in: 0...255)) })
                try garbage.write(to: file)
                #expect(cache.thumbnail(path: path, size: size, modified: modified, longEdge: 160, variant: variant) == nil,
                        "seed=\(hex(seed)) step=\(step): corrupt cache file unexpectedly decoded")

            default:
                // Trim and verify total disk usage is bounded by `byteCap`.
                cache.trim()
                let files = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey])) ?? []
                let totalBytes = files.reduce(0) { acc, url in
                    acc + ((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
                }
                #expect(totalBytes <= cap,
                        "seed=\(hex(seed)) step=\(step): totalBytes=\(totalBytes) exceeded cap=\(cap) after trim()")
            }
        }
        cache.waitForTrim()
    }
}
