import Diagnostics
import Foundation

/// S-6: the `OXYS_*` environment variables (benches, frame and perf logs, contrast probe, open-at-launch) change
/// what the app does, and two of them write files. They work only in the "Bench" build configuration, which sets
/// the `OXYS_DEV_HOOKS` compile condition. In Release the environment seen by hook code is empty, so a release
/// app ignores every one of them. Read the environment through this, never through `ProcessInfo`.
nonisolated enum DevHooks {
    static let environment: [String: String] = {
        #if OXYS_DEV_HOOKS
        return ProcessInfo.processInfo.environment
        #else
        return [:]
        #endif
    }()

    /// Call once, first thing at launch, before anything records a signpost.
    static func start() {
        if let path = environment["OXYS_PERF_LOG"] { Perf.enableLog(path: path) }
    }
}
