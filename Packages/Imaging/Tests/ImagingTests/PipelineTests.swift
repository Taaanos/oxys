import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import Imaging

private func key(_ n: Int, modified: Date = Date(timeIntervalSince1970: 0)) -> FrameKey {
    FrameKey(url: URL(fileURLWithPath: "/photos/\(n).arw"), modified: modified, isRaw: true)
}

// MARK: - ByteBudgetCache

@Test func cacheEvictsLeastRecentlyUsed() {
    var cache = ByteBudgetCache<Int, String>(budget: 30)
    cache.insert("a", cost: 10, for: 1)
    cache.insert("b", cost: 10, for: 2)
    cache.insert("c", cost: 10, for: 3)
    _ = cache.value(for: 1)             // 1 is now newest; 2 is oldest
    cache.insert("d", cost: 10, for: 4)
    #expect(!cache.contains(2))
    #expect(cache.contains(1) && cache.contains(3) && cache.contains(4))
    #expect(cache.totalCost == 30)
}

@Test func cacheNeverExceedsBudgetAndRefusesOversizedEntries() {
    var cache = ByteBudgetCache<Int, Int>(budget: 100)
    for i in 0..<1000 { cache.insert(i, cost: 7 + i % 13, for: i) }
    #expect(cache.totalCost <= 100)
    cache.insert(-1, cost: 101, for: -1)
    #expect(!cache.contains(-1))
    cache.budget = 20
    #expect(cache.totalCost <= 20)
    cache.insert(5, cost: 10, for: 5)
    cache.insert(6, cost: 10, for: 5)   // replacing a key does not double count
    #expect(cache.count <= 2)
}

// MARK: - PrefetchPlan

@Test func prefetchFavorsDirectionOfTravel() {
    let plan = PrefetchPlan()
    let forward = plan.indices(current: 10, count: 100, direction: .forward, slow: false)
    #expect(forward.first == 11)
    #expect(Set(forward) == [11, 12, 13, 14, 9, 8])
    let backward = plan.indices(current: 10, count: 100, direction: .backward, slow: false)
    #expect(backward.first == 9)
    #expect(Set(backward) == [9, 8, 7, 6, 11, 12])
}

@Test func prefetchClampsToTheFolderAndWidensWhenSlow() {
    let plan = PrefetchPlan()
    #expect(Set(plan.indices(current: 0, count: 3, direction: .forward, slow: false)) == [1, 2])
    #expect(plan.indices(current: 0, count: 0, direction: .forward, slow: false).isEmpty)
    #expect(plan.indices(current: 50, count: 100, direction: .forward, slow: true).count == 12)
}

// MARK: - FramePipeline

private actor Recorder {
    var loaded: [Int] = []
    var started: [Int] = []
    var cancelled: [Int] = []
    func started(_ n: Int) { started.append(n) }
    func loaded(_ n: Int) { loaded.append(n) }
    func cancelled(_ n: Int) { cancelled.append(n) }
}

private func number(_ key: FrameKey) -> Int { Int(key.url.deletingPathExtension().lastPathComponent)! }

@Test func pipelineServesRepeatsFromCacheAndPrefetchesNeighbors() async throws {
    let recorder = Recorder()
    let pipeline = FramePipeline<Int>(budget: 1_000) { key in
        await recorder.loaded(number(key))
        return LoadedFrame(frame: number(key), cost: 10)
    }
    let first = try await pipeline.frame(for: key(5), prefetch: [key(6), key(7)])
    #expect(first == 5)
    // Prefetch runs in the background; wait for it.
    for _ in 0..<200 where !(await pipeline.isCached(key(7))) { try await Task.sleep(for: .milliseconds(10)) }
    #expect(await pipeline.isCached(key(6)))
    #expect(await pipeline.isCached(key(7)))
    let again = try await pipeline.frame(for: key(6), prefetch: [])
    #expect(again == 6)
    let counts = await recorder.loaded.reduce(into: [Int: Int]()) { $0[$1, default: 0] += 1 }
    #expect(counts.values.allSatisfy { $0 == 1 })
}

@Test func newerRequestCancelsStaleOnesBeforeTheyDecode() async throws {
    let recorder = Recorder()
    let pipeline = FramePipeline<Int>(budget: 10_000) { key in
        let n = number(key)
        await recorder.started(n)
        do {
            try await Task.sleep(for: .milliseconds(n == 99 ? 5 : 400))   // a slow read
            try Task.checkCancellation()
        } catch { await recorder.cancelled(n); throw error }
        await recorder.loaded(n)
        return LoadedFrame(frame: n, cost: 10)
    }
    let stale = Task { try await pipeline.frame(for: key(1), prefetch: []) }
    try await Task.sleep(for: .milliseconds(50))
    let newest = try await pipeline.frame(for: key(99), prefetch: [])
    #expect(newest == 99)
    #expect(try await stale.value == nil)        // superseded, so it reports nothing to show
    let loaded = await recorder.loaded
    #expect(!loaded.contains(1))
    #expect(await recorder.cancelled.contains(1))
    #expect(!(await pipeline.isCached(key(1))))
}

@Test func pipelineStaysWithinItsBudget() async throws {
    let pipeline = FramePipeline<Int>(budget: 100) { key in LoadedFrame(frame: number(key), cost: 30) }
    for n in 0..<200 { _ = try await pipeline.frame(for: key(n), prefetch: [key(n + 1), key(n + 2)]) }
    #expect(await pipeline.cachedBytes <= 100)
}

@Test func aChangedModificationDateMisses() async throws {
    let recorder = Recorder()
    let pipeline = FramePipeline<Int>(budget: 1_000) { key in
        await recorder.loaded(number(key))
        return LoadedFrame(frame: number(key), cost: 10)
    }
    _ = try await pipeline.frame(for: key(1), prefetch: [])
    _ = try await pipeline.frame(for: key(1, modified: Date(timeIntervalSince1970: 100)), prefetch: [])
    #expect(await recorder.loaded.count == 2)
}

@Test func failuresAreReportedNotCached() async throws {
    struct Boom: Error {}
    let pipeline = FramePipeline<Int>(budget: 1_000) { _ in throw Boom() }
    await #expect(throws: Boom.self) { _ = try await pipeline.frame(for: key(1), prefetch: []) }
    #expect(!(await pipeline.isCached(key(1))))
}

// MARK: - Quick frames (P-03)

@Test func aQuickFrameIsNotCachedAndTheFullFrameStillLoads() async throws {
    let pipeline = FramePipeline<Int>(budget: 1_000, quick: { key in -number(key) }) { key in
        LoadedFrame(frame: number(key), cost: 10)
    }
    #expect(await pipeline.quickFrame(for: key(3)) == -3)
    #expect(await pipeline.cachedBytes == 0)
    #expect(!(await pipeline.isCached(key(3))))
    #expect(try await pipeline.frame(for: key(3), prefetch: []) == 3)
}

@Test func thereIsNoQuickFrameForACachedOrLoadingPhotoOrWithoutALoader() async throws {
    let plain = FramePipeline<Int>(budget: 1_000) { key in LoadedFrame(frame: number(key), cost: 10) }
    #expect(await plain.quickFrame(for: key(1)) == nil)

    let pipeline = FramePipeline<Int>(budget: 1_000, quick: { key in -number(key) }) { key in
        try await Task.sleep(for: .milliseconds(300))
        return LoadedFrame(frame: number(key), cost: 10)
    }
    _ = try await pipeline.frame(for: key(1), prefetch: [])
    #expect(await pipeline.quickFrame(for: key(1)) == nil)          // cached
    let loading = Task { try await pipeline.frame(for: key(2), prefetch: []) }
    try await Task.sleep(for: .milliseconds(50))
    #expect(await pipeline.quickFrame(for: key(2)) == nil)          // already running: waiting is cheaper
    _ = try await loading.value
}

@Test func aQuickFrameStopsTheLoadsOfPhotosTheUserHasLeft() async throws {
    let recorder = Recorder()
    let pipeline = FramePipeline<Int>(budget: 10_000, quick: { key in -number(key) }) { key in
        let n = number(key)
        do {
            try await Task.sleep(for: .milliseconds(400))
            try Task.checkCancellation()
        } catch { await recorder.cancelled(n); throw error }
        await recorder.loaded(n)
        return LoadedFrame(frame: n, cost: 10)
    }
    let behind = Task { try await pipeline.frame(for: key(1), prefetch: [key(2)]) }
    try await Task.sleep(for: .milliseconds(50))
    #expect(await pipeline.quickFrame(for: key(50)) == -50)
    #expect(try await behind.value == nil)
    #expect(await recorder.cancelled.contains(1))
    #expect(!(await recorder.loaded.contains(1)))
}

@Test func aFailingQuickLoadShowsNothingInsteadOfAnError() async {
    struct Boom: Error {}
    let pipeline = FramePipeline<Int>(budget: 1_000, quick: { _ in throw Boom() }) { key in
        LoadedFrame(frame: number(key), cost: 10)
    }
    #expect(await pipeline.quickFrame(for: key(1)) == nil)
}

@Test func theScreenSizeFrameIsAnExactFractionOfThePreview() {
    // 1/4 of 7,008 is 1,752, enough for a 1,920 px screen at 0.75 sharpness; a 2,560 px screen needs 1/2.
    #expect(ScreenSizePolicy.subsampleFactor(sourceLongEdge: 7008, drawableLongEdge: 1920) == 4)
    #expect(ScreenSizePolicy.subsampleFactor(sourceLongEdge: 7008, drawableLongEdge: 2560) == 2)
    #expect(ScreenSizePolicy.subsampleFactor(sourceLongEdge: 5760, drawableLongEdge: 2560) == 2)
    #expect(ScreenSizePolicy.subsampleFactor(sourceLongEdge: 5760, drawableLongEdge: 800) == 8)
    // A rounded-up fraction, so an odd size never falls under the exact scale.
    #expect(ScreenSizePolicy.subsampleFactor(sourceLongEdge: 6001, drawableLongEdge: 2560) == 2)
}

@Test func thereIsNoScreenSizeFrameWhenNoCheapFractionCoversTheScreen() {
    #expect(ScreenSizePolicy.subsampleFactor(sourceLongEdge: 5760, drawableLongEdge: 3840) == 2)    // exactly 0.75
    #expect(ScreenSizePolicy.subsampleFactor(sourceLongEdge: 5000, drawableLongEdge: 3840) == nil)
    #expect(ScreenSizePolicy.subsampleFactor(sourceLongEdge: 960, drawableLongEdge: 2560) == nil)
    #expect(ScreenSizePolicy.subsampleFactor(sourceLongEdge: 6000, drawableLongEdge: 0) == nil)
    #expect(ScreenSizePolicy.subsampleFactor(sourceLongEdge: 0, drawableLongEdge: 1920) == nil)
}

// MARK: - DiskThumbnailCache

private func tempDirectory() -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("oxys-cache-test-\(UUID().uuidString)")
    try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func solidImage(_ width: Int, _ height: Int) -> CGImage {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    context.setFillColor(CGColor(red: 0.2, green: 0.6, blue: 0.9, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    return context.makeImage()!
}

@Test func diskCacheRoundTripsAndKeysOnSizeAndDate() throws {
    let dir = tempDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let cache = DiskThumbnailCache(directory: dir.appendingPathComponent("t"))
    let date = Date(timeIntervalSince1970: 1_000)
    cache.store(solidImage(64, 40), orientation: .right, path: "/p/a.arw", size: 123, modified: date, longEdge: 64)
    let hit = try #require(cache.thumbnail(path: "/p/a.arw", size: 123, modified: date, longEdge: 64))
    #expect(hit.image.width == 64 && hit.image.height == 40)
    #expect(hit.orientation == .right)
    #expect(cache.thumbnail(path: "/p/a.arw", size: 124, modified: date, longEdge: 64) == nil)
    #expect(cache.thumbnail(path: "/p/a.arw", size: 123, modified: date.addingTimeInterval(1), longEdge: 64) == nil)
    #expect(cache.thumbnail(path: "/p/a.arw", size: 123, modified: date, longEdge: 128) == nil)
}

@Test func diskCacheTrimsLeastRecentlyUsedFirst() throws {
    let dir = tempDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let cache = DiskThumbnailCache(directory: dir.appendingPathComponent("t"), byteCap: 1)
    let date = Date(timeIntervalSince1970: 1_000)
    for n in 0..<3 {
        cache.store(solidImage(32, 32), orientation: .up, path: "/p/\(n).arw", size: n, modified: date, longEdge: 32)
        let file = cache.fileURL(path: "/p/\(n).arw", size: n, modified: date, longEdge: 32)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: Double(n - 10))], ofItemAtPath: file.path)
    }
    #expect(cache.totalBytes > 0)
    // Touch the oldest by reading it, then trim to one file's worth.
    _ = cache.thumbnail(path: "/p/0.arw", size: 0, modified: date, longEdge: 32)
    let one = try #require(try FileManager.default.attributesOfItem(
        atPath: cache.fileURL(path: "/p/0.arw", size: 0, modified: date, longEdge: 32).path)[.size] as? Int)
    let capped = DiskThumbnailCache(directory: cache.directory, byteCap: one + one / 2)
    capped.trim()
    #expect(capped.thumbnail(path: "/p/0.arw", size: 0, modified: date, longEdge: 32) != nil)   // recently used
    #expect(capped.thumbnail(path: "/p/1.arw", size: 1, modified: date, longEdge: 32) == nil)
    #expect(capped.thumbnail(path: "/p/2.arw", size: 2, modified: date, longEdge: 32) == nil)
}

@Test func diskCacheClearRemovesOnlyThumbnailsAndKeepsWorking() throws {
    let dir = tempDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let decoyBeside = dir.appendingPathComponent("keep.jpg")
    try Data([9]).write(to: decoyBeside)
    let cache = DiskThumbnailCache(directory: dir.appendingPathComponent("t"))
    let date = Date(timeIntervalSince1970: 1_000)
    for n in 0..<3 {
        cache.store(solidImage(32, 32), orientation: .up, path: "/p/\(n).arw", size: n, modified: date, longEdge: 32)
    }
    let before = cache.totalBytes
    #expect(before > 0)
    #expect(cache.clear() == before)
    #expect(cache.totalBytes == 0)
    #expect(cache.thumbnail(path: "/p/0.arw", size: 0, modified: date, longEdge: 32) == nil)
    #expect(FileManager.default.fileExists(atPath: decoyBeside.path))
    // It fills again, and clearing an absent folder is harmless.
    cache.store(solidImage(32, 32), orientation: .up, path: "/p/0.arw", size: 0, modified: date, longEdge: 32)
    #expect(cache.thumbnail(path: "/p/0.arw", size: 0, modified: date, longEdge: 32) != nil)
    try FileManager.default.removeItem(at: cache.directory)
    #expect(cache.clear() == 0)
}

@Test func diskCacheNeverWritesIntoThePhotoFolder() throws {
    let photos = tempDirectory(), caches = tempDirectory()
    defer { try? FileManager.default.removeItem(at: photos); try? FileManager.default.removeItem(at: caches) }
    try Data([1, 2, 3]).write(to: photos.appendingPathComponent("a.arw"))
    let before = try FileManager.default.contentsOfDirectory(atPath: photos.path)
    let cache = DiskThumbnailCache(directory: caches.appendingPathComponent("t"))
    cache.store(solidImage(16, 16), orientation: .up, path: photos.appendingPathComponent("a.arw").path, size: 3,
                modified: .now, longEdge: 16)
    #expect(try FileManager.default.contentsOfDirectory(atPath: photos.path) == before)
    #expect(!cache.directory.path.hasPrefix(photos.path))
    #expect(DiskThumbnailCache.standardDirectory(bundleID: "dev.oxys.Oxys").path.contains("/Library/Caches/dev.oxys.Oxys/"))
}

@Test func loadsInFlightTakeTheirWorkingMemoryOutOfTheCache() async throws {
    // Budget 100, frames cost 20, a load needs 2x its cost while it runs: with 3 loads at once the cache
    // may hold 100 - 3 * 40 -> floored at 50. Once the loads end the cache stays within the full 100.
    let pipeline = FramePipeline<Int>(budget: 100, transientFactor: 2) { key in
        try await Task.sleep(for: .milliseconds(20))
        return LoadedFrame(frame: number(key), cost: 20)
    }
    for n in 0..<30 { _ = try await pipeline.frame(for: key(n), prefetch: [key(n + 1), key(n + 2)]) }
    try await Task.sleep(for: .milliseconds(100))
    #expect(await pipeline.cachedBytes <= 100)
}

@Test func aCancelledLoadKeepsItsReservationUntilItEnds() async throws {
    // The load below ignores its cancellation for 200 ms, as a decode or an upload does. The pipeline must keep
    // counting its working memory until it returns, not until it was cancelled.
    let pipeline = FramePipeline<Int>(budget: 1_000, transientFactor: 2) { key in
        // A detached task does not see the load's cancellation, so this wait runs its full length.
        if number(key) == 1 { await Task.detached { try? await Task.sleep(for: .milliseconds(200)) }.value }
        else { try await Task.sleep(for: .milliseconds(5)) }
        return LoadedFrame(frame: number(key), cost: 100)
    }
    _ = try await pipeline.frame(for: key(0), prefetch: [])   // the pipeline now knows a frame costs 100
    let slow = Task { try await pipeline.frame(for: key(1), prefetch: []) }
    try await Task.sleep(for: .milliseconds(50))
    _ = try await pipeline.frame(for: key(2), prefetch: [])   // cancels key 1; its task still runs
    #expect(await pipeline.running >= 1)
    #expect(await pipeline.budgetForCache <= 1_000 - 200)     // at least one load is reserved
    _ = try await slow.value
    for _ in 0..<100 where await pipeline.running > 0 { try await Task.sleep(for: .milliseconds(10)) }
    #expect(await pipeline.running == 0)
    #expect(await pipeline.budgetForCache == 1_000)
}

@Test func pipelineReportsIdleOnlyWhenNoLoadIsRunning() async throws {
    let pipeline = FramePipeline<Int>(budget: 1_000) { key in
        try await Task.sleep(for: .milliseconds(100))
        return LoadedFrame(frame: number(key), cost: 10)
    }
    #expect(await pipeline.isIdle)
    let load = Task { try await pipeline.frame(for: key(1), prefetch: [key(2)]) }
    try await Task.sleep(for: .milliseconds(30))
    #expect(!(await pipeline.isIdle))
    _ = try await load.value
    for _ in 0..<200 where !(await pipeline.isIdle) { try await Task.sleep(for: .milliseconds(10)) }
    #expect(await pipeline.isIdle)
    #expect(await pipeline.isCached(key(2)))
}

// MARK: - One memory budget (P-04)

@Test func theFrameCacheGivesWayToDevelopedRaws() async throws {
    let memory = MemoryBudget(total: 1_000)
    let pipeline = FramePipeline<Int>(budget: 1_000, memory: memory) { key in LoadedFrame(frame: number(key), cost: 100) }
    memory.setUsed(.raw, 400)
    for n in 0..<10 { _ = try await pipeline.frame(for: key(n), prefetch: []) }
    #expect(await pipeline.cachedBytes <= 600)
    #expect(memory.used <= 1_000)
    // The frames never go under a quarter of the total, however much the RAWs hold.
    memory.setUsed(.raw, 900)
    for n in 10..<20 { _ = try await pipeline.frame(for: key(n), prefetch: []) }
    #expect(await pipeline.cachedBytes <= 300)   // the floor is 250; frames cost 100 each
}

@Test func developedRawsKeepWithinTheirShare() async throws {
    let memory = MemoryBudget(total: 1_000)
    let cache = RawFrameCache<Int>(maxCount: 100, budget: memory)
    memory.setUsed(.frames, 700)
    for n in 0..<10 { _ = try await cache.develop(key(n)) { LoadedFrame(frame: number($0), cost: 100) } }
    #expect(cache.totalCost <= 300)
    #expect(cache.count >= 1)
    #expect(memory.used == 700 + cache.totalCost)
    cache.trim(keeping: key(9))
    #expect(cache.count == 1 && cache.contains(key(9)))
    cache.removeAll()
    #expect(memory.used == 700)
}

@Test func aWarningKeepsTheFrameOnScreenAndTwoNeighborsAndCriticalOnlyTheFrame() async throws {
    let pipeline = FramePipeline<Int>(budget: 10_000) { key in LoadedFrame(frame: number(key), cost: 100) }
    let window = (1...6).map { key($0) }
    _ = try await pipeline.frame(for: key(0), prefetch: window)
    for _ in 0..<200 where await pipeline.cachedBytes < 700 { try await Task.sleep(for: .milliseconds(10)) }
    #expect(await pipeline.cachedBytes == 700)
    await pipeline.setPressure(.warning)
    #expect(await pipeline.cachedBytes == 300)
    let kept = [await pipeline.isCached(key(0)), await pipeline.isCached(key(1)), await pipeline.isCached(key(2))]
    #expect(kept == [true, true, true])
    await pipeline.setPressure(.critical)
    #expect(await pipeline.cachedBytes == 100)
    #expect(await pipeline.isCached(key(0)))
    // Under critical pressure a new request loads its target and nothing else.
    _ = try await pipeline.frame(for: key(3), prefetch: [key(4), key(5)])
    try await Task.sleep(for: .milliseconds(100))
    #expect(!(await pipeline.isCached(key(4))))
}

@Test func aHeldKeyLoadsTheTargetOnlyAndThePrefetchStartsWhenTheKeyIsUp() async throws {
    let recorder = Recorder()
    let pipeline = FramePipeline<Int>(budget: 10_000, prefetchHold: .milliseconds(80)) { key in
        await recorder.loaded(number(key))
        return LoadedFrame(frame: number(key), cost: 10)
    }
    // A key held down: a new target every 20 ms, each with a window.
    for n in 0..<5 {
        _ = try await pipeline.frame(for: key(n), prefetch: [key(n + 1), key(n + 2)])
        try await Task.sleep(for: .milliseconds(20))
    }
    #expect(await recorder.loaded == [0, 1, 2, 3, 4])
    // The key goes up: the window of the last target loads.
    try await Task.sleep(for: .milliseconds(300))
    let window = [await pipeline.isCached(key(5)), await pipeline.isCached(key(6))]
    #expect(window == [true, true])
}

@Test func whenTheFramesFillUpTheDevelopedRawsGiveBack() async throws {
    let memory = MemoryBudget(total: 1_000)
    let raws = RawFrameCache<Int>(maxCount: 100, budget: memory)
    let pipeline = FramePipeline<Int>(budget: 1_000, memory: memory) { key in LoadedFrame(frame: number(key), cost: 100) }
    for n in 0..<8 { _ = try await raws.develop(key(100 + n)) { LoadedFrame(frame: number($0), cost: 100) } }
    // The RAWs hold 800 of 1,000; the frames come in and take what the floor gives them. The RAWs give back.
    for n in 0..<10 { _ = try await pipeline.frame(for: key(n), prefetch: []) }
    for _ in 0..<100 where memory.used > 1_000 { try await Task.sleep(for: .milliseconds(10)) }
    #expect(memory.used <= 1_000)
    #expect(raws.count >= 1)
}

@Test func aHolderThatCannotGoLowerDoesNotLoopTheBudget() async throws {
    // One RAW over the whole total: the cache keeps its newest entry, so the budget stays over. It must not recurse.
    let memory = MemoryBudget(total: 100)
    let raws = RawFrameCache<Int>(maxCount: 5, budget: memory)
    memory.setUsed(.frames, 60)
    _ = try await raws.develop(key(1)) { LoadedFrame(frame: number($0), cost: 500) }
    _ = try await raws.develop(key(2)) { LoadedFrame(frame: number($0), cost: 500) }
    #expect(raws.count == 1)
    #expect(memory.used == 560)
}
