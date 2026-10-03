import AppKit
import Darwin

/// Cold-launch measurement for F-01 (formal check is M-26).
/// Does nothing unless OXYS_REPORT_LAUNCH is set in the environment.
enum LaunchMetrics {
    private static let environment = DevHooks.environment

    static func reportFirstWindow() {
        guard environment["OXYS_REPORT_LAUNCH"] != nil,
              let elapsed = secondsSinceProcessStart() else { return }
        let line = String(format: "launch-to-first-draw: %.0f ms\n", elapsed * 1000)
        FileHandle.standardOutput.write(Data(line.utf8))
        DispatchQueue.main.async { NSApp.terminate(nil) }
    }

    private static func secondsSinceProcessStart() -> Double? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0) == 0 else { return nil }
        let started = info.kp_proc.p_starttime
        let startTime = Double(started.tv_sec) + Double(started.tv_usec) / 1_000_000
        return Date().timeIntervalSince1970 - startTime
    }
}
