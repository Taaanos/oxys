import Foundation
import Metadata
import Sidecar
import Synchronization

/// Limits how many ImageIO opens of RAW and TIFF files run at the same time, across every reader (P-08 crash).
///
/// ImageIO hands these files to Apple's RawCamera plugin. The plugin keeps a shared cache, and with many opens at once
/// it can release a cached value twice: one crash report showed a segmentation fault in `_value_entry_release` with ten
/// threads inside the plugin. The capture-time pass (8 wide) and the embedded-XMP fallback of the sidecar pass
/// (4 wide) each had their own width, so together 12 opens overlapped. One limit for both keeps the total low.
/// It cannot remove Apple's race. It makes the overlap smaller, and the folder open stays as fast as it was.
///
/// A task that waits is suspended, not blocked, so it does not hold a thread of the cooperative pool. Waiters go
/// first in, first out, so neither pass starves the other. A task that is cancelled while it waits still takes its
/// turn, as its read did before the gate existed.
final class ImageIOGate: Sendable {
    /// 8 is the highest limit that costs the folder open about 5% (scan-5000: 3.6 s to 3.8 s). 6 cost 12%, 4 cost 24%.
    static let shared = ImageIOGate(limit: 8)

    private struct State {
        var running = 0
        var waiting: [CheckedContinuation<Void, Never>] = []
    }

    let limit: Int
    private let state = Mutex(State())

    init(limit: Int) { self.limit = max(1, limit) }

    /// Runs `body` when fewer than `limit` bodies are running. `body` is synchronous on purpose: the slot is held
    /// for exactly one ImageIO call and is never held across a suspension.
    func run<T: Sendable>(_ body: @Sendable () -> T) async -> T {
        await acquire()
        defer { release() }
        return body()
    }

    /// Like `run`, but a file that does not go through RawCamera (`needed` false) skips the gate.
    func run<T: Sendable>(if needed: Bool, _ body: @Sendable () -> T) async -> T {
        needed ? await run(body) : body()
    }

    private func acquire() async {
        let free = state.withLock { state in
            guard state.running < limit else { return false }
            state.running += 1
            return true
        }
        if free { return }
        await withCheckedContinuation { continuation in
            // The slot may have been released between the check above and here.
            let granted = state.withLock { state in
                guard state.running >= limit else { state.running += 1; return true }
                state.waiting.append(continuation)
                return false
            }
            if granted { continuation.resume() }
        }
    }

    private func release() {
        let next = state.withLock { state in
            // A waiter takes over the slot, so `running` stays as it is.
            if state.waiting.isEmpty { state.running -= 1; return nil as CheckedContinuation<Void, Never>? }
            return state.waiting.removeFirst()
        }
        next?.resume()
    }
}

extension PhotoFormat {
    /// True when ImageIO reads the file through Apple's RawCamera plugin. JPEG and HEIC have their own readers.
    /// TIFF is counted too: it costs one gate check and the plugin's cache is the thing we protect.
    var readsThroughRawCamera: Bool {
        switch self {
        case .jpeg, .heic: false
        default: true
        }
    }
}

/// The two ImageIO readers of a folder open, behind the shared gate.
enum GatedRead {
    static func captureTime(of url: URL, format: PhotoFormat) async -> Date? {
        await ImageIOGate.shared.run(if: format.readsThroughRawCamera) { CaptureTime.read(from: url) }
    }

    /// Only a file without a sidecar whose format can hold XMP inside reaches ImageIO; the rest needs no slot.
    static func sidecar(of url: URL, format: PhotoFormat, index: SidecarIndex, naming: SidecarNaming) async -> SidecarReadResult {
        await ImageIOGate.shared.run(if: format.hasEmbeddedXMP && format.readsThroughRawCamera) {
            SidecarReader.read(photo: url, embeddedFallback: format.hasEmbeddedXMP, index: index, naming: naming)
        }
    }
}
