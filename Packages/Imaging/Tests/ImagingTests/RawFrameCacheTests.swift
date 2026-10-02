import Foundation
import Testing
@testable import Imaging

private func key(_ n: Int) -> FrameKey {
    FrameKey(url: URL(fileURLWithPath: "/photos/\(n).arw"), modified: Date(timeIntervalSince1970: 0), isRaw: true)
}

private func loaded(_ n: Int, cost: Int = 10) -> LoadedFrame<Int> { LoadedFrame(frame: n, cost: cost) }

@Test func rawCacheHoldsAtMostFiveAndDropsTheLeastRecentlyUsed() async throws {
    let cache = RawFrameCache<Int>(maxCount: 5)
    for n in 1...5 { _ = try await cache.develop(key(n)) { _ in loaded(n) } }
    _ = cache.cached(key(1))                       // 1 is newest, 2 is oldest
    _ = try await cache.develop(key(6)) { _ in loaded(6) }
    #expect(cache.count == 5)
    #expect(!cache.contains(key(2)))
    #expect(cache.contains(key(1)) && cache.contains(key(6)))
}

@Test func rawCacheKeepsTheNewestEvenWhenOverTheByteCap() async throws {
    let cache = RawFrameCache<Int>(maxCount: 5, maxBytes: 25)
    for n in 1...3 { _ = try await cache.develop(key(n)) { _ in loaded(n, cost: 20) } }
    #expect(cache.count == 1 && cache.contains(key(3)))
}

@Test func rawCacheReturnsAHitWithoutLoading() async throws {
    let cache = RawFrameCache<Int>()
    _ = try await cache.develop(key(1)) { _ in loaded(1) }
    let again = try await cache.develop(key(1)) { _ in Issue.record("loaded twice"); return loaded(99) }
    #expect(again == 1)
}

@Test func cancelledDevelopIsDroppedNotCached() async throws {
    let cache = RawFrameCache<Int>()
    let started = AsyncStream<Void>.makeStream()
    let request = Task {
        try await cache.develop(key(1)) { _ in
            started.continuation.yield()
            // A decode that cannot be stopped mid-render: it finishes even after the cancel.
            try await Task.sleep(for: .milliseconds(200))
            return loaded(1)
        }
    }
    for await _ in started.stream { break }
    cache.cancelInflight()
    let result = try await request.value
    #expect(result == nil)
    #expect(!cache.contains(key(1)))
    #expect(!cache.isDeveloping)
}

@Test func askingForAnotherPhotoCancelsTheRunningDevelop() async throws {
    let cache = RawFrameCache<Int>()
    let started = AsyncStream<Void>.makeStream()
    let first = Task {
        try await cache.develop(key(1)) { _ in
            started.continuation.yield()
            try await Task.sleep(for: .seconds(5))      // stops when cancelled
            return loaded(1)
        }
    }
    for await _ in started.stream { break }
    let second = try await cache.develop(key(2)) { _ in loaded(2) }
    #expect(second == 2)
    #expect(try await first.value == nil)
    #expect(cache.contains(key(2)) && !cache.contains(key(1)))
}

@Test func failedDevelopIsNotCachedAndTheErrorReachesTheCaller() async throws {
    let cache = RawFrameCache<Int>()
    await #expect(throws: RawDevelopError.self) {
        _ = try await cache.develop(key(1)) { _ in throw RawDevelopError.unsupported }
    }
    #expect(cache.count == 0 && !cache.isDeveloping)
}

@Test func removeAllEmptiesTheCache() async throws {
    let cache = RawFrameCache<Int>()
    _ = try await cache.develop(key(1)) { _ in loaded(1) }
    cache.removeAll()
    #expect(cache.count == 0)
}

@Test func bgraHistogramReadsBlueGreenRedOrder() {
    // Two pixels: pure red (B 0, G 0, R 255) and pure blue.
    let h = Histogram.compute(bgra: [0, 0, 255, 255, 255, 0, 0, 255], pixelCount: 2, source: .raw)
    #expect(h.red[255] == 1 && h.red[0] == 1)
    #expect(h.blue[255] == 1 && h.blue[0] == 1)
    #expect(h.green[0] == 2)
    #expect(h.source == .raw)
}

// MARK: - RawDeveloper (needs corpus files, which are not in the repo; skipped when absent)

private let corpus = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("TestData")

@Test(.enabled(if: FileManager.default.fileExists(atPath: corpus.appendingPathComponent("DSC01014.ARW").path)))
func neutralFilterSwitchesDetailOffAndKeepsTheFullSensorSize() throws {
    let filter = try RawDeveloper.neutralFilter(for: corpus.appendingPathComponent("DSC01014.ARW"), minLongEdge: 1024)
    #expect(filter.nativeSize.width >= 1024)
    if filter.isSharpnessSupported { #expect(filter.sharpnessAmount == 0) }
    if filter.isLuminanceNoiseReductionSupported { #expect(filter.luminanceNoiseReductionAmount == 0) }
    if filter.isColorNoiseReductionSupported { #expect(filter.colorNoiseReductionAmount == 0) }
    if filter.isLensCorrectionSupported { #expect(!filter.isLensCorrectionEnabled) }
    let extent = try #require(filter.outputImage).extent
    #expect(extent.size == CGSize(width: 5472, height: 3648))   // Sony ARW, 20 MP, no crop
}

@Test(.enabled(if: FileManager.default.fileExists(atPath: corpus.appendingPathComponent("Adobe DNG Converter - Canon EOS 5D Mark III - 16bit 16bit uncompressed (3_2).tiff").path)))
func aDNGNamedTiffIsDevelopedThroughAContainerHint() throws {
    let url = corpus.appendingPathComponent("Adobe DNG Converter - Canon EOS 5D Mark III - 16bit 16bit uncompressed (3_2).tiff")
    let filter = try RawDeveloper.neutralFilter(for: url, minLongEdge: 1024)
    #expect(try #require(filter.outputImage).extent.width > 4000)
}

@Test func aFileThatIsNotARawIsUnsupported() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("not-a-raw-\(UUID().uuidString).arw")
    try Data(repeating: 7, count: 4096).write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }
    #expect(throws: RawDevelopError.unsupported) { try RawDeveloper.neutralFilter(for: url, minLongEdge: 1024) }
}

@Test func rawCacheLowerCountEvictsTheLeastRecentlyUsedAtOnce() async throws {
    let cache = RawFrameCache<Int>(maxCount: 5)
    for n in 1...5 { _ = try await cache.develop(key(n)) { _ in loaded(n) } }
    cache.setLimits(maxCount: 2, maxBytes: .max)
    #expect(cache.count == 2)
    #expect(cache.contains(key(4)) && cache.contains(key(5)))
}

@Test func rawCacheBytesLimitWinsOverAHighCount() async throws {
    let cache = RawFrameCache<Int>(maxCount: 10, maxBytes: 25)
    for n in 1...6 { _ = try await cache.develop(key(n)) { _ in loaded(n, cost: 10) } }
    #expect(cache.count == 2)
}

@Test func rawCacheRaisingLimitsKeepsEverythingAndCountIsAtLeastOne() async throws {
    let cache = RawFrameCache<Int>(maxCount: 3)
    for n in 1...3 { _ = try await cache.develop(key(n)) { _ in loaded(n) } }
    cache.setLimits(maxCount: 10, maxBytes: .max)
    #expect(cache.count == 3 && cache.maxCount == 10)
    cache.setLimits(maxCount: 0, maxBytes: .max)
    #expect(cache.maxCount == 1 && cache.count == 1)
}
