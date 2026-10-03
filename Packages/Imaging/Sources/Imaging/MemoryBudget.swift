import Synchronization

/// One byte budget for everything that holds decoded frames (P-04): the preview frame cache with its loads in
/// flight, and the developed RAWs. Each holder reports what it uses and asks what it may keep: the total less what
/// the other holds. A holder is never squeezed under its floor (a quarter of the total), so the frame on screen
/// and its neighbors stay.
/// When the two together go over the total, the holder that is over its floor is told to give back.
public final class MemoryBudget: Sendable {
    public enum Holder: Sendable { case frames, raw }

    private struct State {
        var total: Int
        var frames = 0
        var raw = 0
        var shrinkFrames: (@Sendable () -> Void)?
        var shrinkRaw: (@Sendable () -> Void)?
        var enforcing = false
    }

    private let state: Mutex<State>

    public init(total: Int) { state = Mutex(State(total: total)) }

    public var total: Int { state.withLock { $0.total } }
    /// Bytes the holders report together (for tests and the bench).
    public var used: Int { state.withLock { $0.frames + $0.raw } }

    public func setTotal(_ bytes: Int) {
        state.withLock { $0.total = bytes }
        enforce()
    }

    /// `shrink` runs, outside any lock, when the holders together are over the total and this one is over its floor.
    /// It must bring the holder to `share(of:)`, and report its new use with `setUsed`.
    public func register(_ holder: Holder, shrink: @escaping @Sendable () -> Void) {
        state.withLock { s in
            switch holder {
            case .frames: s.shrinkFrames = shrink
            case .raw: s.shrinkRaw = shrink
            }
        }
    }

    /// What `holder` holds now.
    public func setUsed(_ holder: Holder, _ bytes: Int) {
        state.withLock { s in
            switch holder {
            case .frames: s.frames = bytes
            case .raw: s.raw = bytes
            }
        }
        enforce()
    }

    /// The least a holder is left with: a quarter of the total.
    public var floor: Int { state.withLock { $0.total / 4 } }

    /// What `holder` may keep: the total less the other holder's use, but at least its floor.
    public func share(of holder: Holder) -> Int {
        state.withLock { s in
            switch holder {
            case .frames: max(s.total - s.raw, s.total / 4)
            case .raw: max(s.total - s.frames, s.total / 4)
            }
        }
    }

    private func enforce() {
        // A shrink reports its new use, which comes back here: one pass at a time, or it would never end when a
        // holder cannot go lower (the newest RAW always stays).
        let shrinks: [@Sendable () -> Void] = state.withLock { s in
            guard !s.enforcing, s.frames + s.raw > s.total else { return [] }
            var result: [@Sendable () -> Void] = []
            if s.frames > s.total / 4, let f = s.shrinkFrames { result.append(f) }
            if s.raw > s.total / 4, let r = s.shrinkRaw { result.append(r) }
            s.enforcing = !result.isEmpty
            return result
        }
        guard !shrinks.isEmpty else { return }
        for shrink in shrinks { shrink() }
        state.withLock { $0.enforcing = false }
    }
}
