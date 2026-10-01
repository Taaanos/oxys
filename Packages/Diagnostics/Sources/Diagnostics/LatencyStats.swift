/// Percentiles over latency samples, in milliseconds.
public struct LatencyStats: Sendable, Equatable {
    public var count: Int
    public var p50: Double
    public var p95: Double
    public var max: Double

    /// Nearest-rank percentiles: the value at rank ⌈p·n⌉ of the sorted samples, so every reported
    /// number is a latency that actually happened (no interpolation between two real ones).
    public init?(samples: [Double]) {
        guard !samples.isEmpty else { return nil }
        let sorted = samples.sorted()
        count = sorted.count
        p50 = Self.percentile(0.50, of: sorted)
        p95 = Self.percentile(0.95, of: sorted)
        max = sorted[sorted.count - 1]
    }

    static func percentile(_ p: Double, of sorted: [Double]) -> Double {
        let rank = Int((p * Double(sorted.count)).rounded(.up))
        return sorted[Swift.min(Swift.max(rank, 1), sorted.count) - 1]
    }
}

/// Renders the latency table `PerfTool report` prints.
public enum LatencyTable {
    public static func render(_ rows: [(name: String, stats: LatencyStats)]) -> String {
        func pad(_ s: String, _ w: Int, left: Bool = false) -> String {
            let fill = String(repeating: " ", count: Swift.max(0, w - s.count))
            return left ? s + fill : fill + s
        }
        func ms(_ v: Double) -> String {
            let r = (v * 100).rounded() / 100
            let whole = Int(r), frac = Int(((r - Double(whole)) * 100).rounded())
            return "\(whole).\(frac < 10 ? "0" : "")\(frac)"
        }
        let nameWidth = Swift.max(8, rows.map(\.name.count).max() ?? 0)
        var lines = [pad("interval", nameWidth, left: true) + pad("n", 8) + pad("p50 ms", 10) + pad("p95 ms", 10) + pad("max ms", 10)]
        lines.append(String(repeating: "-", count: lines[0].count))
        for (name, s) in rows {
            lines.append(pad(name, nameWidth, left: true) + pad("\(s.count)", 8) + pad(ms(s.p50), 10) + pad(ms(s.p95), 10) + pad(ms(s.max), 10))
        }
        return lines.joined(separator: "\n")
    }
}
