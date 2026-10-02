import Foundation
import Testing
@testable import Diagnostics

@Suite struct PerfGateTests {
    @Test func parsesTargetsAndSkipsCommentsAndBlankLines() throws {
        let text = "# header\n\nnav-cold\tkey-to-frame\tp95\t100\tNext image, cold\ngrid\tgrid-frame-ms\tmax\t25\tGrid\tgrid-10000\ncull\tsidecar-write\tp95\t-\tSidecar\n"
        let targets = try GateTarget.parse(text)
        #expect(targets.count == 3)
        #expect(targets[0] == GateTarget(scenario: "nav-cold", interval: "key-to-frame", statistic: .p95, limit: 100, prdRow: "Next image, cold"))
        #expect(targets[1].folder == "grid-10000")
        #expect(targets[2].limit == nil)
    }

    @Test func rejectsBadRows() {
        #expect(throws: GateTarget.ParseError.self) { try GateTarget.parse("a\tb\tp95\n") }
        #expect(throws: GateTarget.ParseError.self) { try GateTarget.parse("a\tb\tp99\t1\tx\n") }
        #expect(throws: GateTarget.ParseError.self) { try GateTarget.parse("a\tb\tp95\tfast\tx\n") }
    }

    @Test func logKeepsOrderAndIgnoresBadLines() {
        let log = PerfLog(text: "b\t2\na\t1\nb\t4\nnot a line\nc\tx\n")
        #expect(log.order == ["b", "a"])
        #expect(log.samples["b"] == [2, 4])
    }

    @Test func frameLogCountsStaleFrames() {
        var log = PerfLog()
        log.addFrameLog(text: "A.ARW\tA.ARW\tpreview\nB.ARW\tA.ARW\tpreview\n-\tC.ARW\tpreview\nD.ARW\tD.ARW\tthumbnail\n")
        #expect(log.samples["frames-logged"] == [4])
        #expect(log.samples["stale-frames"] == [1])
    }

    @Test func statisticsFollowTheTarget() {
        let log = PerfLog(text: (1...100).map { "key-to-frame\t\($0)" }.joined(separator: "\n"))
        func target(_ s: GateTarget.Statistic) -> GateTarget { GateTarget(scenario: "x", interval: "key-to-frame", statistic: s, limit: 50, prdRow: "") }
        #expect(target(.p50).value(in: log) == 50)
        #expect(target(.p95).value(in: log) == 95)
        #expect(target(.max).value(in: log) == 100)
        #expect(target(.peak).value(in: log) == 100)
        #expect(GateTarget(scenario: "x", interval: "absent", statistic: .max, limit: 1, prdRow: "").value(in: log) == nil)
    }

    @Test func verdictUsesTheMedianRun() {
        let target = GateTarget(scenario: "x", interval: "t", statistic: .max, limit: 50, prdRow: "")
        func run(_ v: Double) -> PerfLog { PerfLog(text: "t\t\(v)\n") }
        // One slow outlier among three runs does not fail the gate; two do.
        #expect(GateResult(target: target, logs: [run(40), run(90), run(45)]).verdict == .pass)
        #expect(GateResult(target: target, logs: [run(40), run(90), run(80)]).verdict == .fail)
        #expect(GateResult(target: target, logs: [run(50)]).verdict == .pass)   // the limit itself passes
        #expect(GateResult(target: target, logs: [PerfLog()]).verdict == .noData)
    }

    @Test func reportOnlyRowsNeverFail() {
        let target = GateTarget(scenario: "x", interval: "t", statistic: .max, limit: nil, prdRow: "")
        let result = GateResult(target: target, logs: [PerfLog(text: "t\t999\n")])
        #expect(result.verdict == .report)
        #expect(GateReport.passed([result]))
    }

    @Test func reportFailsOnAFailOrMissingData() {
        let limit = GateTarget(scenario: "x", interval: "t", statistic: .max, limit: 1, prdRow: "")
        let ok = GateResult(target: limit, logs: [PerfLog(text: "t\t1\n")])
        let bad = GateResult(target: limit, logs: [PerfLog(text: "t\t2\n")])
        let missing = GateResult(target: limit, logs: [PerfLog()])
        #expect(GateReport.passed([ok]))
        #expect(!GateReport.passed([ok, bad]))
        #expect(!GateReport.passed([ok, missing]))
        #expect(GateReport.render([ok, bad]).contains("FAIL"))
    }
}
