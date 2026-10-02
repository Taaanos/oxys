// F-02 tool.
//   PerfTool selftest              emit synthetic intervals (to check the recording pipeline end to end)
//   PerfTool report <file.trace>   print p50/p95/max per interval from an Instruments trace
//   PerfTool log <file>            the same table from an OXYS_PERF_LOG file (M-26)
import Diagnostics
import Foundation

let args = Array(CommandLine.arguments.dropFirst())
switch args.first {
case "selftest":
    // Sleeps give each interval a known duration: key-to-frame ≈ 4 ms, decode ≈ 10 ms, the rest ≈ 1 ms.
    let work: [(PerfInterval, UInt32)] = [(.keyToFrame, 4_000), (.previewRead, 1_000), (.decode, 10_000),
                                          (.textureUpload, 1_000), (.sidecarWrite, 1_000)]
    for _ in 0..<50 {
        for (interval, micros) in work {
            let token = Perf.begin(interval)
            usleep(micros)
            Perf.end(token)
        }
    }
case "report" where args.count == 2:
    do {
        let samples = try TraceReader.intervalDurations(traceAt: args[1])
        let rows = PerfInterval.allCases.compactMap { i in
            LatencyStats(samples: samples[i.rawValue] ?? []).map { (name: i.rawValue, stats: $0) }
        }
        if rows.isEmpty {
            FileHandle.standardError.write(Data("no \(Perf.subsystem) signpost intervals in \(args[1])\n".utf8))
            exit(1)
        }
        print(LatencyTable.render(rows))
    } catch {
        FileHandle.standardError.write(Data("report failed: \(error)\n".utf8))
        exit(1)
    }
case "log" where args.count == 2:
    guard let text = try? String(contentsOfFile: args[1], encoding: .utf8) else {
        FileHandle.standardError.write(Data("cannot read \(args[1])\n".utf8))
        exit(1)
    }
    var byName: [String: [Double]] = [:]
    var order: [String] = []
    for line in text.split(separator: "\n") {
        let parts = line.split(separator: "\t")
        guard parts.count == 2, let value = Double(parts[1]) else { continue }
        let name = String(parts[0])
        if byName[name] == nil { order.append(name) }
        byName[name, default: []].append(value)
    }
    let rows = order.compactMap { n in LatencyStats(samples: byName[n] ?? []).map { (name: n, stats: $0) } }
    print(LatencyTable.render(rows))
default:
    FileHandle.standardError.write(Data("usage: PerfTool selftest | report <file.trace> | log <file>\n".utf8))
    exit(2)
}
