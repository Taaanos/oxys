import Foundation
import Synchronization
import Testing
@testable import Library

@Suite struct ImageIOGateTests {
    /// How many bodies run now and the most that ever ran together.
    private final class Probe: Sendable {
        private let state = Mutex((now: 0, peak: 0, done: 0))
        func enter() { state.withLock { $0.now += 1; $0.peak = max($0.peak, $0.now) } }
        func leave() { state.withLock { $0.now -= 1; $0.done += 1 } }
        var peak: Int { state.withLock { $0.peak } }
        var done: Int { state.withLock { $0.done } }
    }

    /// `DispatchSemaphore.wait` may not be called straight from async code; this keeps the test thread-blocking on purpose.
    private func waitFor(_ semaphore: DispatchSemaphore) { semaphore.wait() }

    @Test(arguments: [1, 3, 8])
    func neverRunsMoreBodiesThanTheLimit(limit: Int) async {
        let gate = ImageIOGate(limit: limit)
        let probe = Probe()
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<60 {
                group.addTask {
                    await gate.run {
                        probe.enter()
                        Thread.sleep(forTimeInterval: 0.003)
                        probe.leave()
                    }
                }
            }
        }
        #expect(probe.done == 60)
        #expect(probe.peak <= limit)
        #expect(probe.peak >= 1)
    }

    @Test func returnsTheBodysValue() async {
        let gate = ImageIOGate(limit: 2)
        let values = await withTaskGroup(of: Int.self) { group in
            for n in 0..<20 { group.addTask { await gate.run { n * n } } }
            var all: [Int] = []
            for await value in group { all.append(value) }
            return all.sorted()
        }
        #expect(values == (0..<20).map { $0 * $0 })
    }

    @Test func aFileThatNeedsNoSlotDoesNotWaitForOne() async {
        let gate = ImageIOGate(limit: 1)
        let release = DispatchSemaphore(value: 0)
        let started = DispatchSemaphore(value: 0)
        let holder = Task.detached {
            await gate.run {
                started.signal()
                release.wait()
            }
        }
        waitFor(started)
        // The only slot is taken. A JPEG-like read must still go through at once.
        let value = await gate.run(if: false) { 42 }
        #expect(value == 42)
        release.signal()
        await holder.value
    }

    @Test func aWaiterTakesTheSlotWhenItIsReleased() async {
        let gate = ImageIOGate(limit: 1)
        let release = DispatchSemaphore(value: 0)
        let started = DispatchSemaphore(value: 0)
        let holder = Task.detached {
            await gate.run {
                started.signal()
                release.wait()
            }
        }
        waitFor(started)
        let waiter = Task.detached { await gate.run { "ran" } }
        // Give the waiter time to queue behind the holder; it cannot finish before the holder lets go.
        try? await Task.sleep(for: .milliseconds(50))
        release.signal()
        #expect(await waiter.value == "ran")
        await holder.value
    }

    @Test func aLimitBelowOneStillAllowsOne() async {
        let gate = ImageIOGate(limit: 0)
        #expect(gate.limit == 1)
        #expect(await gate.run { 7 } == 7)
    }

    @Test func onlyFormatsReadByRawCameraAreGated() {
        for format in PhotoFormat.allCases {
            #expect(format.readsThroughRawCamera == (format != .jpeg && format != .heic), "\(format)")
        }
    }
}
