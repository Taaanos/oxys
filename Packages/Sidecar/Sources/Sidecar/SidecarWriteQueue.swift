import Foundation
import Synchronization

/// Saves decisions off the main thread. Only the latest edit per sidecar is kept while a write is pending, so a
/// burst of keys on one photo costs one write, and `submit` never waits for the disk.
public final class SidecarWriteQueue: Sendable {
    private struct Job { var target: SidecarTarget; var edit: SidecarEdit; var removeIfCreated: Bool }

    /// Mutually exclusive worker states: cannot be idle while a file is in flight.
    private enum Worker {
        case idle
        case draining(inFlight: URL?)
    }

    private struct State {
        var pending: [URL: Job] = [:]
        var order: [URL] = []
        var worker: Worker = .idle
    }

    /// Mutually exclusive failure states for a sidecar URL (replaces two separate mutexes that could race or overlap).
    private enum UnsavedStatus {
        case retryable(Job)
        case refused
    }

    /// What a sidecar looked like right after our last write or removal, without a `[URL: FileSignature?]` double-optional trap.
    private enum RecordedFileState {
        case exists(FileSignature?)
        case removed
    }

    private let state = Mutex(State())
    /// The exact bytes of each sidecar this queue created and has not seen changed since (touched only on the
    /// write queue). An undo may delete such a file; any other file is patched instead (M-09/Q1).
    private let created = Mutex<[URL: Data]>([:])
    /// What each sidecar looked like right after our last write or removal of it.
    /// FSEvents echoes our own writes back; a file that still looks like this was not touched by anyone else (M-10).
    private let signatures = Mutex<[URL: RecordedFileState]>([:])
    /// Sidecars whose latest write failed (retryable) or was refused (unpatchable), in one lock so counts and transitions are atomic.
    private let unsaved = Mutex<[URL: UnsavedStatus]>([:])
    private let queue = DispatchQueue(label: "com.thanosam.oxys.sidecar-write", qos: .utility)
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
        // A newer decision supersedes an older failure or refusal; if it fails too it is recorded again.
        unsaved.withLock { $0[target.primary] = nil }
        let schedule = state.withLock { state -> Bool in
            let job = Job(target: target, edit: edit, removeIfCreated: removeIfCreatedByUs)
            if state.pending.updateValue(job, forKey: target.primary) == nil {
                state.order.append(target.primary)
            }
            if case .idle = state.worker {
                state.worker = .draining(inFlight: nil)
                return true
            }
            return false
        }
        if schedule { queue.async { [self] in drain() } }
    }

    /// True while a decision for this sidecar is queued or being written, so a change from outside arrives
    /// on top of a user edit that has not reached the disk yet (M-10/Q2).
    public func hasPendingWrite(for url: URL) -> Bool {
        state.withLock { state in
            if case .draining(let current) = state.worker, current == url { return true }
            return state.pending.contains { $0.key == url || $0.value.target.fallback == url }
        }
    }

    /// True when `url` is exactly as our last write (or removal) left it, so a change event for it is an echo.
    public func isOwnWrite(_ url: URL) -> Bool {
        guard let recorded = signatures.withLock({ $0[url] }) else { return false }
        let current = FileSignature(of: url)
        switch recorded {
        case .exists(let expected): return current == expected
        case .removed: return current == nil
        }
    }

    /// How many sidecars have a decision that is not on disk: the last write failed or was refused (M-11).
    /// Exact once `flush()` has returned, which is what the quit prompt relies on.
    public var unsavedCount: Int { unsaved.withLock { $0.count } }

    /// Drops the failed write for a sidecar whose decision has been saved somewhere else (M-11).
    public func forgetFailure(for primary: URL) {
        unsaved.withLock { $0[primary] = nil }
    }

    /// Submits every failed write again, unless a newer decision for that sidecar is already queued.
    /// Returns how many were resubmitted.
    @discardableResult
    public func retryFailed() -> Int {
        let retryable: [(URL, Job)] = unsaved.withLock { map in
            var jobs: [(URL, Job)] = []
            for (url, status) in map {
                if case .retryable(let job) = status {
                    jobs.append((url, job))
                    map[url] = nil
                }
            }
            return jobs
        }
        var count = 0
        for (key, job) in retryable {
            let schedule = state.withLock { state -> Bool? in
                guard state.pending[key] == nil else { return nil }
                state.pending[key] = job
                state.order.append(key)
                if case .idle = state.worker {
                    state.worker = .draining(inFlight: nil)
                    return true
                }
                return false
            }
            guard let schedule else { continue }
            count += 1
            if schedule { queue.async { [self] in drain() } }
        }
        return count
    }

    private func drain() {
        while true {
            let job = state.withLock { state -> Job? in
                guard !state.order.isEmpty else { state.worker = .idle; return nil }
                let job = state.pending.removeValue(forKey: state.order.removeFirst())
                state.worker = .draining(inFlight: job.map { SidecarWriter.resolve($0.target) })
                return job
            }
            guard let job else { return }
            let outcome = run(job)
            switch outcome {
            case .written(let url):
                signatures.withLock { $0[url] = .exists(FileSignature(of: url)) }
                unsaved.withLock { $0[job.target.primary] = nil }
            case .removed(let url):
                signatures.withLock { $0[url] = .removed }
                unsaved.withLock { $0[job.target.primary] = nil }
            case .failed:
                unsaved.withLock { $0[job.target.primary] = .retryable(job) }
            case .refused:
                unsaved.withLock { $0[job.target.primary] = .refused }
            }
            onOutcome(outcome)
        }
    }

    private func run(_ job: Job) -> SidecarWriteOutcome {
        let fm = FileManager.default
        let url = SidecarWriter.resolve(job.target)
        let exists = fm.fileExists(atPath: url.path)
        var current: Data?
        if exists, case .data(let data)? = try? SidecarReader.readBounded(url) { current = data }
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
