import Foundation
import Testing
@testable import Diagnostics

// MARK: - Deterministic PRNG (SplitMix64)

private struct SeededRNG {
    private var state: UInt64

    init(seed: UInt64) { self.state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    mutating func int(in range: ClosedRange<Int>) -> Int {
        let span = UInt64(range.upperBound - range.lowerBound) + 1
        return range.lowerBound + Int(next() % span)
    }

    mutating func double(in range: ClosedRange<Double>) -> Double {
        let u = Double(next() & 0x001F_FFFF_FFFF_FFFF) / Double(0x0020_0000_0000_0000)
        return range.lowerBound + u * (range.upperBound - range.lowerBound)
    }

    mutating func bool(probability num: Int = 1, outOf den: Int = 2) -> Bool {
        Int(next() % UInt64(den)) < num
    }

    mutating func pick<T>(_ items: [T]) -> T {
        items[Int(next() % UInt64(items.count))]
    }

    mutating func shuffled<T>(_ array: [T]) -> [T] {
        var copy = array
        guard copy.count > 1 else { return copy }
        for i in stride(from: copy.count - 1, through: 1, by: -1) {
            let j = int(in: 0...i)
            copy.swapAt(i, j)
        }
        return copy
    }
}

private func hex(_ seed: UInt64) -> String { "0x" + String(seed, radix: 16, uppercase: true) }

// MARK: - Suite 1: LatencyStats Differential & Invariant Tests

@Suite struct DiagnosticsSimulationTests {
    @Test(arguments: [UInt64(0x9101), 0x9102, 0x9103, 0x9104, 0x9105, 0x9106])
    func latencyStatsMatchesOracleAndObeysInvariants(seed: UInt64) throws {
        var rng = SeededRNG(seed: seed)

        for step in 0..<100 {
            let n = rng.int(in: 1...250)
            let samples = (0..<n).map { _ in rng.double(in: 0.0...5000.0) }
            let stats = try #require(LatencyStats(samples: samples))
            let sorted = samples.sorted()

            // Ordering and exact-sample (nearest-rank, never interpolated) invariants
            #expect(stats.count == n)
            #expect(sorted[0] <= stats.p50 && stats.p50 <= stats.p95 && stats.p95 <= stats.max,
                    "seed=\(hex(seed)) step=\(step): percentile ordering violated")
            #expect(samples.contains(stats.p50) && samples.contains(stats.p95) && samples.contains(stats.max),
                    "seed=\(hex(seed)) step=\(step): nearest-rank percentile was not an actual sample")
            #expect(stats.max == sorted.last)

            // Nearest-rank oracle: at least 50% of samples <= p50 and at least 95% <= p95
            let le50 = sorted.filter { $0 <= stats.p50 }.count
            let le95 = sorted.filter { $0 <= stats.p95 }.count
            #expect(Double(le50) / Double(n) >= 0.50 - 1e-12, "seed=\(hex(seed)) step=\(step): p50 too low")
            #expect(Double(le95) / Double(n) >= 0.95 - 1e-12, "seed=\(hex(seed)) step=\(step): p95 too low")

            // Permutation invariance
            let shuffled = rng.shuffled(samples)
            #expect(LatencyStats(samples: shuffled) == stats,
                    "seed=\(hex(seed)) step=\(step): LatencyStats depended on input order")

            // Positive scale equivariance
            let factor = rng.double(in: 0.1...10.0)
            let scaled = try #require(LatencyStats(samples: samples.map { $0 * factor }))
            #expect(abs(scaled.p50 - stats.p50 * factor) < 1e-9)
            #expect(abs(scaled.p95 - stats.p95 * factor) < 1e-9)
            #expect(abs(scaled.max - stats.max * factor) < 1e-9)

            // Table rendering smoke check
            let rendered = LatencyTable.render([("interval_\(step)", stats)])
            #expect(rendered.contains("interval_\(step)") && rendered.contains("\(n)"))
        }
    }

    @Test(arguments: [UInt64(0x9201), 0x9202, 0x9203, 0x9204])
    func signpostIntervalXMLDifferentialAndMutationFuzz(seed: UInt64) throws {
        var rng = SeededRNG(seed: seed)
        let subsystems = ["com.thanosam.Oxys", "com.apple.other", "com.test.aux"]
        let names = ["frameLoad", "sidecarWrite", "rawDevelop", "gridScroll", "memoryRelief"]

        // 1. Differential round-trip with xctrace id/ref de-duplication
        for batch in 0..<25 {
            var xml = "<trace-query-result><node><table schema=\"os-signpost-interval\">\n"
            var nameIDs: [String: String] = [:]
            var subIDs: [String: String] = [:]
            var nextID = 1
            var expected: [SignpostInterval] = []

            let rowCount = rng.int(in: 1...40)
            for _ in 0..<rowCount {
                let name = rng.pick(names)
                let sub = rng.pick(subsystems)
                let dur = rng.int(in: 0...5_000_000_000)
                expected.append(SignpostInterval(name: name, subsystem: sub, durationNanoseconds: dur))

                let nameTag: String
                if let id = nameIDs[name], rng.bool(probability: 3, outOf: 4) {
                    nameTag = "<signpost-name ref=\"\(id)\"/>"
                } else {
                    let id = "n\(nextID)"; nextID += 1
                    nameIDs[name] = id
                    nameTag = "<signpost-name id=\"\(id)\">\(name)</signpost-name>"
                }

                let subTag: String
                if let id = subIDs[sub], rng.bool(probability: 3, outOf: 4) {
                    subTag = "<subsystem ref=\"\(id)\"/>"
                } else {
                    let id = "s\(nextID)"; nextID += 1
                    subIDs[sub] = id
                    subTag = "<subsystem id=\"\(id)\">\(sub)</subsystem>"
                }

                xml += "  <row>\(nameTag)\(subTag)<duration>\(dur)</duration></row>\n"
            }
            xml += "</table></node></trace-query-result>"

            let parsed = try SignpostIntervalXML.parse(Data(xml.utf8))
            #expect(parsed == expected, "seed=\(hex(seed)) batch=\(batch): SignpostIntervalXML mismatch")

            let oxysDurations = parsed.durations(subsystem: "com.thanosam.Oxys")
            let expectedOxys = Dictionary(grouping: expected.filter { $0.subsystem == "com.thanosam.Oxys" }, by: \.name)
                .mapValues { $0.map(\.durationMilliseconds) }
            #expect(oxysDurations == expectedOxys, "seed=\(hex(seed)) batch=\(batch): durations(subsystem:) mismatch")
        }

        // 2. Mutation / corruption fuzz: must never crash or trap
        let baseXML = Array("<r><row><signpost-name id=\"1\">a</signpost-name><subsystem id=\"2\">s</subsystem><duration>100</duration></row><row><signpost-name ref=\"1\"/><subsystem ref=\"999\"/><duration>bad</duration></row></r>".utf8)
        for _ in 0..<200 {
            var bytes = rng.bool(probability: 3, outOf: 4) ? baseXML : (0..<rng.int(in: 0...128)).map { _ in UInt8(rng.int(in: 0...255)) }
            if !bytes.isEmpty {
                switch rng.int(in: 0...2) {
                case 0: bytes = Array(bytes.prefix(rng.int(in: 0...(bytes.count - 1))))
                case 1:
                    for _ in 0..<rng.int(in: 1...6) { bytes[rng.int(in: 0...(bytes.count - 1))] = UInt8(rng.int(in: 0...255)) }
                default: break
                }
            }
            _ = try? SignpostIntervalXML.parse(Data(bytes))
        }
    }

    @Test(arguments: [UInt64(0x9301), 0x9302, 0x9303, 0x9304])
    func perfGateDifferentialAndFuzzInvariants(seed: UInt64) throws {
        var rng = SeededRNG(seed: seed)
        let stats: [GateTarget.Statistic] = [.p50, .p95, .max, .peak]

        for batch in 0..<25 {
            var tsvLines = ["# comment line", ""]
            var expectedTargets: [GateTarget] = []
            let targetCount = rng.int(in: 1...8)
            for i in 0..<targetCount {
                let stat = rng.pick(stats)
                let hasLimit = rng.bool(probability: 3, outOf: 4)
                let limit: Double? = hasLimit ? Double(rng.int(in: 10...500)) : nil
                let limitCol = limit.map { String(Int($0)) } ?? "-"
                let folder: String? = rng.bool(probability: 1, outOf: 3) ? "bench-\(i)" : nil
                let cols = ["scen-\(i)", "int-\(i)", stat.rawValue, limitCol, "PRD-\(i)"] + (folder.map { [$0] } ?? [])
                tsvLines.append(cols.joined(separator: "\t"))
                expectedTargets.append(GateTarget(scenario: "scen-\(i)", interval: "int-\(i)",
                                                  statistic: stat, limit: limit, prdRow: "PRD-\(i)", folder: folder))
            }

            let parsed = try GateTarget.parse(tsvLines.joined(separator: "\n"))
            #expect(parsed == expectedTargets, "seed=\(hex(seed)) batch=\(batch): GateTarget.parse mismatch")

            // Build 3 randomized PerfLogs and cross-check GateResult median + verdict oracle.
            var results: [GateResult] = []
            for t in parsed {
                var logs: [PerfLog] = []
                var runValues: [Double] = []
                for _ in 0..<3 {
                    var lines: [String] = []
                    if rng.bool(probability: 4, outOf: 5) {
                        var vals: [Double] = []
                        for _ in 0..<rng.int(in: 1...25) {
                            let v = Double(rng.int(in: 1...800))
                            vals.append(v)
                            lines.append("\(t.interval)\t\(v)")
                        }
                        if let st = LatencyStats(samples: vals) {
                            let runV = switch t.statistic {
                            case .p50: st.p50
                            case .p95: st.p95
                            case .max, .peak: st.max
                            }
                            runValues.append(runV)
                        }
                    }
                    logs.append(PerfLog(text: lines.joined(separator: "\n")))
                }
                let result = GateResult(target: t, logs: logs)
                results.append(result)

                if runValues.isEmpty {
                    #expect(result.outcome == .noData && result.verdict == .noData)
                } else {
                    let sorted = runValues.sorted()
                    let median = sorted[(sorted.count - 1) / 2]
                    if let limit = t.limit {
                        let expected: GateOutcome = median <= limit ? .passed(value: median, limit: limit) : .failed(value: median, limit: limit)
                        #expect(result.outcome == expected, "seed=\(hex(seed)) batch=\(batch): outcome mismatch")
                    } else {
                        #expect(result.outcome == .reported(value: median))
                    }
                }
            }

            let expectedPass = results.allSatisfy { $0.verdict == .pass || $0.verdict == .report }
            #expect(GateReport.passed(results) == expectedPass, "seed=\(hex(seed)) batch=\(batch): GateReport.passed mismatch")
            let rendered = GateReport.render(results)
            for r in results { #expect(rendered.contains(r.target.scenario)) }
        }

        // Fuzz malformed TSV / PerfLog / FrameLog lines: must never crash.
        for _ in 0..<150 {
            let garbage = (0..<rng.int(in: 0...6)).map { _ in
                rng.pick(["", "# c", "a\tb", "s\ti\tbad\t10\tr", "s\ti\tp50\tnotnum\tr", "a\t12.5", "-\tfoo\tbar", "x\ty\tz"])
            }.joined(separator: "\n")
            _ = try? GateTarget.parse(garbage)
            var log = PerfLog(text: garbage)
            log.addFrameLog(text: garbage)
        }
    }
}
