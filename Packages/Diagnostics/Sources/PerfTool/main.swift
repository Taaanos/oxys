// F-02 tool.
//   PerfTool selftest              emit synthetic intervals (to check the recording pipeline end to end)
//   PerfTool report <file.trace>   print p50/p95/max per interval from an Instruments trace
//   PerfTool log <file>            the same table from an OXYS_PERF_LOG file (M-26)
//   PerfTool gate <targets.tsv> <scenario>[@<folder>]=<log>[,<log>…] …   hold runs to the PRD limits (P-01)
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
    let log = PerfLog(text: text)
    let rows = log.order.compactMap { n in LatencyStats(samples: log.samples[n] ?? []).map { (name: n, stats: $0) } }
    print(LatencyTable.render(rows))
case "gate" where args.count >= 3:
    // PerfTool gate <targets.tsv> <scenario>[@<folder>]=<log>[,<log>…] …  (P-01)
    // Holds each scenario's runs to the limits in the targets file; prints the table; exits 1 on a fail or a missing number.
    // A log's frame log (`<log>.frames`), when there is one, adds `frames-logged` and `stale-frames`.
    func read(_ path: String) -> String? { try? String(contentsOfFile: path, encoding: .utf8) }
    guard let targetText = read(args[1]) else {
        FileHandle.standardError.write(Data("cannot read \(args[1])\n".utf8))
        exit(2)
    }
    do {
        let targets = try GateTarget.parse(targetText)
        var results: [GateResult] = []
        for spec in args.dropFirst(2) {
            let halves = spec.split(separator: "=", maxSplits: 1).map(String.init)
            guard halves.count == 2 else {
                FileHandle.standardError.write(Data("expected <scenario>=<log>[,<log>…], got \(spec)\n".utf8))
                exit(2)
            }
            let logs: [PerfLog] = halves[1].split(separator: ",").map { path in
                var log = PerfLog(text: read(String(path)) ?? "")
                if let frames = read(path + ".frames") { log.addFrameLog(text: frames) }
                return log
            }
            // `<scenario>` takes the rows with no folder, `<scenario>@<folder>` the rows for that folder.
            let key = halves[0].split(separator: "@", maxSplits: 1).map(String.init)
            results += targets.filter { $0.scenario == key[0] && $0.folder == (key.count > 1 ? key[1] : nil) }
                .map { GateResult(target: $0, logs: logs) }
        }
        print(GateReport.render(results))
        exit(GateReport.passed(results) ? 0 : 1)
    } catch {
        FileHandle.standardError.write(Data("\(error)\n".utf8))
        exit(2)
    }
default:
    FileHandle.standardError.write(Data("usage: PerfTool selftest | report <file.trace> | log <file> | gate <targets.tsv> <scenario>[@<folder>]=<log>[,<log>…] …\n".utf8))
    exit(2)
}
