import Foundation
import Synchronization

/// Saves decisions off the main thread. Only the latest edit per sidecar is kept while a write is pending, so a
/// burst of keys on one photo costs one write, and `submit` never waits for the disk.
public final class SidecarWriteQueue: Sendable {
    private struct Job { var target: SidecarTarget; var edit: SidecarEdit; var removeIfCreated: Bool }
    private struct State {
        var pending: [URL: Job] = [:]
        var order: [URL] = []
        var scheduled = false
        var inFlight: URL?
    }

    private let state = Mutex(State())
    /// The exact bytes of each sidecar this queue created and has not seen changed since (touched only on the
    /// write queue). An undo may delete such a file; any other file is patched instead (M-09/Q1).
    private let created = Mutex<[URL: Data]>([:])
    /// What each sidecar looked like right after our last write or removal of it (nil: the file is gone).
    /// FSEvents echoes our own writes back; a file that still looks like this was not touched by anyone else (M-10).
    private let signatures = Mutex<[URL: FileSignature?]>([:])
    private let queue = DispatchQueue(label: "dev.oxys.sidecar-write", qos: .utility)
    private let onOutcome: @Sendable (SidecarWriteOutcome) -> Void
    private let now: @Sendable () -> Date

    public init(now: @escaping @Sendable () -> Date = { Date() },
                onOutcome: @escaping @Sendable (SidecarWriteOutcome) -> Void = { _ in }) {
        self.now = now
        self.onOutcome = onOutcome
    }

    /// `removeIfCreatedByUs` is for an undo that returns a photo to "no decision": if the sidecar is one this
    /// queue created and nobody has touched, it is deleted rather than rewritten with rating 0.
    public func submit(_ edit: SidecarEdit, to target: SidecarTarget, removeIfCreatedByUs: Bool = false) {
        let schedule = state.withLock { state -> Bool in
            let job = Job(target: target, edit: edit, removeIfCreated: removeIfCreatedByUs)
            if state.pending.updateValue(job, forKey: target.primary) == nil {
                state.order.append(target.primary)
            }
            defer { state.scheduled = true }
            return !state.scheduled
        }
        if schedule { queue.async { [self] in drain() } }
    }

    /// True while a decision for this sidecar is queued or being written, so a change from outside arrives
    /// on top of a user edit that has not reached the disk yet (M-10/Q2).
    public func hasPendingWrite(for url: URL) -> Bool {
        state.withLock { state in
            state.inFlight == url || state.pending.contains { $0.key == url || $0.value.target.fallback == url }
        }
    }

    /// True when `url` is exactly as our last write (or removal) left it, so a change event for it is an echo.
    public func isOwnWrite(_ url: URL) -> Bool {
        guard let recorded = signatures.withLock({ $0[url] }) else { return false }
        return recorded == FileSignature(of: url)
    }

    private func drain() {
        while true {
            let job = state.withLock { state -> Job? in
                guard !state.order.isEmpty else { state.scheduled = false; state.inFlight = nil; return nil }
                let job = state.pending.removeValue(forKey: state.order.removeFirst())
                state.inFlight = job.map { SidecarWriter.resolve($0.target) }
                return job
            }
            guard let job else { return }
            let outcome = run(job)
            switch outcome {
            case .written(let url): signatures.withLock { $0[url] = .some(FileSignature(of: url)) }
            case .removed(let url): signatures.withLock { $0[url] = .some(nil) }
            case .refused, .failed: break
            }
            onOutcome(outcome)
        }
    }

    private func run(_ job: Job) -> SidecarWriteOutcome {
        let fm = FileManager.default
        let url = SidecarWriter.resolve(job.target)
        let exists = fm.fileExists(atPath: url.path)
        let current = exists ? try? Data(contentsOf: url) : nil
        let ours = created.withLock { $0[url] }
        if job.removeIfCreated {
            if !exists {
                created.withLock { $0[url] = nil }
                return .removed(url)
            }
            if let ours, ours == current {
                do { try fm.removeItem(at: url) } catch { return .failed(url, reason: error.localizedDescription) }
                created.withLock { $0[url] = nil }
                return .removed(url)
            }
        }
        let result = SidecarWriter.writeReturningBytes(job.edit, to: job.target, now: now())
        if case .written = result.outcome {
            created.withLock { map in
                if !exists { map[url] = result.bytes } else if let ours, ours == current { map[url] = result.bytes } else { map[url] = nil }
            }
        }
        return result.outcome
    }

    /// Blocks until everything submitted so far is on disk. For quit, and for tests.
    public func flush() {
        queue.sync {}
    }
}
