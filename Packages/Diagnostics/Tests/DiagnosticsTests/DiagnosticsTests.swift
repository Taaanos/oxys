import Foundation
import Testing
@testable import Diagnostics

@Suite struct LatencyStatsTests {
    @Test func emptyHasNoStats() {
        #expect(LatencyStats(samples: []) == nil)
    }

    @Test func singleSample() throws {
        let s = try #require(LatencyStats(samples: [4]))
        #expect(s.count == 1 && s.p50 == 4 && s.p95 == 4 && s.max == 4)
    }

    @Test func nearestRankOnOneToHundred() throws {
        let s = try #require(LatencyStats(samples: (1...100).map(Double.init).shuffled()))
        #expect(s.p50 == 50)
        #expect(s.p95 == 95)
        #expect(s.max == 100)
    }

    @Test func smallSetsRoundRankUp() throws {
        // ⌈0.5·4⌉ = 2nd value, ⌈0.95·4⌉ = 4th.
        let s = try #require(LatencyStats(samples: [40, 10, 30, 20]))
        #expect(s.p50 == 20)
        #expect(s.p95 == 40)
    }

    @Test func outlierShowsInP95NotP50() throws {
        let s = try #require(LatencyStats(samples: Array(repeating: 3, count: 94) + Array(repeating: 90, count: 6)))
        #expect(s.p50 == 3)
        #expect(s.p95 == 90)
    }
}

@Suite struct PerfIntervalTests {
    @Test func namesAreUniqueAndKebabCase() {
        let names = PerfInterval.allCases.map(\.rawValue)
        #expect(Set(names).count == names.count)
        #expect(names.allSatisfy { $0 == $0.lowercased() && !$0.contains(" ") })
    }

    @Test func staticNamesMatchRawValues() {
        for i in PerfInterval.allCases {
            #expect(i.signpostName.description == i.rawValue)
        }
    }

    @Test func measureReturnsBodyValueAndRethrows() {
        #expect(Perf.measure(.decode) { 7 } == 7)
        struct Boom: Error {}
        #expect(throws: Boom.self) { try Perf.measure(.decode) { throw Boom() } }
    }
}

@Suite struct LatencyTableTests {
    @Test func rendersAlignedRows() throws {
        let s = try #require(LatencyStats(samples: [1.234, 2, 3]))
        let out = LatencyTable.render([(name: "decode", stats: s)])
        #expect(out.contains("decode"))
        #expect(out.contains("2.00"))   // p50
        #expect(out.contains("3.00"))   // p95
    }
}

@Suite struct SignpostIntervalXMLTests {
    /// Shape copied from a real export: repeated names and subsystems come back as `ref` elements.
    static let xml = """
    <?xml version="1.0"?><trace-query-result><node xpath='x'><schema name="OSSignpostIntervals"></schema>
    <row><start-time id="1">1</start-time><duration id="2" fmt="5.02 ms">5021416</duration><signpost-name id="4">key-to-frame</signpost-name><category id="5">Performance</category><subsystem id="6">com.thanosam.Oxys</subsystem></row>
    <row><start-time>9</start-time><duration id="20">1500000</duration><signpost-name id="21">decode</signpost-name><subsystem ref="6"/></row>
    <row><start-time>12</start-time><duration ref="2"/><signpost-name ref="4"/><subsystem ref="6"/></row>
    <row><start-time>13</start-time><duration id="30">7</duration><signpost-name id="31">other</signpost-name><subsystem id="32">com.apple.foo</subsystem></row>
    </node></trace-query-result>
    """

    @Test func resolvesRefsAndFiltersBySubsystem() throws {
        let all = try SignpostIntervalXML.parse(Data(Self.xml.utf8))
        #expect(all.count == 4)
        #expect(all[2] == SignpostInterval(name: "key-to-frame", subsystem: "com.thanosam.Oxys", durationNanoseconds: 5_021_416))
        let ours = all.durations(subsystem: "com.thanosam.Oxys")
        #expect(ours["key-to-frame"]?.count == 2)
        #expect(ours["decode"] == [1.5])
        #expect(ours["other"] == nil)
    }

    @Test func malformedXMLThrows() {
        #expect(throws: (any Error).self) { try SignpostIntervalXML.parse(Data("<row><duration>".utf8)) }
    }
}
