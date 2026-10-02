import Foundation

/// One run's numbers: every `name<TAB>value` line of an `OXYS_PERF_LOG` file, in order of first appearance (M-26).
public struct PerfLog: Sendable, Equatable {
    public private(set) var samples: [String: [Double]] = [:]
    public private(set) var order: [String] = []

    public init() {}

    public init(text: String) {
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: "\t")
            guard parts.count == 2, let value = Double(parts[1]) else { continue }
            add(String(parts[0]), value)
        }
    }

    public mutating func add(_ name: String, _ value: Double) {
        if samples[name] == nil { order.append(name) }
        samples[name, default: []].append(value)
    }

    /// Adds `frames-logged` and `stale-frames` from a frame log (`OXYS_FRAME_LOG`, lines of
    /// `cursor<TAB>displayed<TAB>kind`). A frame is stale when the photo shown is not the one the cursor is on.
    public mutating func addFrameLog(text: String) {
        var logged = 0.0, stale = 0.0
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard parts.count >= 2 else { continue }
            logged += 1
            if parts[0] != "-", parts[0] != parts[1] { stale += 1 }
        }
        add("frames-logged", logged)
        add("stale-frames", stale)
    }
}

/// One row of `scripts/perf-targets.tsv`: a PRD limit as a number a run can be held to.
public struct GateTarget: Sendable, Equatable {
    public enum Statistic: String, Sendable { case p50, p95, max, peak }

    /// The scenario that produces the interval (`nav-cold`, `cull`, …). `-slow` scenarios run with a loader delay.
    public var scenario: String
    public var interval: String
    public var statistic: Statistic
    /// The value must not exceed this. Nil (`-` in the file) means the row is reported but cannot fail.
    public var limit: Double?
    public var prdRow: String
    /// A bench folder name the scenario must run on (`scan-5000`), or nil for the folder under test.
    public var folder: String?

    public init(scenario: String, interval: String, statistic: Statistic, limit: Double?, prdRow: String, folder: String? = nil) {
        self.scenario = scenario
        self.interval = interval
        self.statistic = statistic
        self.limit = limit
        self.prdRow = prdRow
        self.folder = folder
    }

    public struct ParseError: Error, Equatable, CustomStringConvertible {
        public let line: Int
        public let reason: String
        public var description: String { "perf-targets line \(line): \(reason)" }
    }

    /// Columns, tab separated: scenario, interval, statistic, limit, PRD row, folder (optional).
    /// Blank lines and lines starting with `#` are skipped.
    public static func parse(_ text: String) throws -> [GateTarget] {
        var targets: [GateTarget] = []
        for (index, raw) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let line = String(raw)
            if line.trimmingCharacters(in: .whitespaces).isEmpty || line.hasPrefix("#") { continue }
            let cols = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard cols.count >= 5 else { throw ParseError(line: index + 1, reason: "needs 5 tab-separated columns") }
            guard let statistic = Statistic(rawValue: cols[2]) else {
                throw ParseError(line: index + 1, reason: "unknown statistic '\(cols[2])' (p50, p95, max, peak)")
            }
            var limit: Double?
            if cols[3] != "-" {
                guard let value = Double(cols[3]) else { throw ParseError(line: index + 1, reason: "limit '\(cols[3])' is not a number or '-'") }
                limit = value
            }
            let folder = cols.count > 5 && !cols[5].isEmpty ? cols[5] : nil
            targets.append(GateTarget(scenario: cols[0], interval: cols[1], statistic: statistic, limit: limit, prdRow: cols[4], folder: folder))
        }
        return targets
    }

    /// The statistic over one run's samples; nil when the run did not record the interval.
    public func value(in log: PerfLog) -> Double? {
        guard let stats = LatencyStats(samples: log.samples[interval] ?? []) else { return nil }
        switch statistic {
        case .p50: return stats.p50
        case .p95: return stats.p95
        case .max, .peak: return stats.max
        }
    }
}

public enum GateVerdict: String, Sendable { case pass, fail, report, noData = "no data" }

/// A target held against the runs of its scenario. The gate value is the median of the runs' values (P-01 Q2).
public struct GateResult: Sendable, Equatable {
    public var target: GateTarget
    public var runs: [Double?]
    public var value: Double? {
        let present = runs.compactMap { $0 }.sorted()
        guard !present.isEmpty else { return nil }
        return present[(present.count - 1) / 2]
    }
    public var verdict: GateVerdict {
        guard let value else { return .noData }
        guard let limit = target.limit else { return .report }
        return value <= limit ? .pass : .fail
    }

    public init(target: GateTarget, logs: [PerfLog]) {
        self.target = target
        runs = logs.map { target.value(in: $0) }
    }
}

public enum GateReport {
    /// True when no row failed or lacks data.
    public static func passed(_ results: [GateResult]) -> Bool {
        !results.contains { $0.verdict == .fail || $0.verdict == .noData }
    }

    public static func render(_ results: [GateResult]) -> String {
        func number(_ v: Double?) -> String {
            guard let v else { return "-" }
            let r = (v * 100).rounded() / 100
            return r == r.rounded() ? String(Int(r)) : String(r)
        }
        let header = ["scenario", "interval", "stat", "limit", "runs", "median", "result", "PRD row"]
        var rows = [header]
        for r in results {
            rows.append([r.target.scenario, r.target.interval, r.target.statistic.rawValue, number(r.target.limit),
                         r.runs.map(number).joined(separator: " "), number(r.value), r.verdict.rawValue.uppercased(), r.target.prdRow])
        }
        let widths = header.indices.map { c in rows.map { $0[c].count }.max() ?? 0 }
        return rows.enumerated().map { index, row in
            let line = row.indices.map { c in row[c] + String(repeating: " ", count: widths[c] - row[c].count) }
                .joined(separator: "  ")
            return index == 0 ? line + "\n" + String(repeating: "-", count: line.count) : line
        }.joined(separator: "\n")
    }
}
