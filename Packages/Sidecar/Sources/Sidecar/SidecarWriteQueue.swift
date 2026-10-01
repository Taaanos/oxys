import Foundation
import Synchronization

/// Saves decisions off the main thread. Only the latest edit per sidecar is kept while a write is pending, so a
/// burst of keys on one photo costs one write, and `submit` never waits for the disk.
public final class SidecarWriteQueue: Sendable {
    private struct Job { var target: SidecarTarget; var edit: SidecarEdit }
    private struct State {
        var pending: [URL: Job] = [:]
        var order: [URL] = []
        var scheduled = false
    }

    private let state = Mutex(State())
    private let queue = DispatchQueue(label: "dev.oxys.sidecar-write", qos: .utility)
    private let onOutcome: @Sendable (SidecarWriteOutcome) -> Void
    private let now: @Sendable () -> Date

    public init(now: @escaping @Sendable () -> Date = { Date() },
                onOutcome: @escaping @Sendable (SidecarWriteOutcome) -> Void = { _ in }) {
        self.now = now
        self.onOutcome = onOutcome
    }

    public func submit(_ edit: SidecarEdit, to target: SidecarTarget) {
        let schedule = state.withLock { state -> Bool in
            if state.pending.updateValue(Job(target: target, edit: edit), forKey: target.primary) == nil {
                state.order.append(target.primary)
            }
            defer { state.scheduled = true }
            return !state.scheduled
        }
        if schedule { queue.async { [self] in drain() } }
    }

    private func drain() {
        while true {
            let job = state.withLock { state -> Job? in
                guard !state.order.isEmpty else { state.scheduled = false; return nil }
                return state.pending.removeValue(forKey: state.order.removeFirst())
            }
            guard let job else { return }
            onOutcome(SidecarWriter.write(job.edit, to: job.target, now: now()))
        }
    }

    /// Blocks until everything submitted so far is on disk. For quit, and for tests.
    public func flush() {
        queue.sync {}
    }
}
