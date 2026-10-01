import Diagnostics
import Foundation

enum TraceReader {
    /// Exports the signpost intervals of every run in the trace and groups durations (ms) by interval name.
    static func intervalDurations(traceAt path: String) throws -> [String: [Double]] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/xctrace")
        p.arguments = ["export", "--input", path, "--xpath", #"/trace-toc/run/data/table[@schema="OSSignpostIntervals"]"#]
        let pipe = Pipe()
        p.standardOutput = pipe
        try p.run()
        let xml = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw CocoaError(.fileReadUnknown) }
        return try SignpostIntervalXML.parse(xml).durations(subsystem: Perf.subsystem)
    }
}
