import Foundation
import Testing
@testable import Metadata

@Suite struct CaptureTimeTests {
    let utc = TimeZone(secondsFromGMT: 0)!

    @Test func parsesPlainTimeInTheGivenZone() throws {
        let date = try #require(CaptureTime.parse(dateTimeOriginal: "2026:09:30 14:05:09", timeZone: utc))
        #expect(date.timeIntervalSince1970 == 1_790_777_109)
    }

    @Test func subsecondsKeepBurstFramesInOrder() throws {
        let a = try #require(CaptureTime.parse(dateTimeOriginal: "2026:09:30 14:05:09", subseconds: "07", timeZone: utc))
        let b = try #require(CaptureTime.parse(dateTimeOriginal: "2026:09:30 14:05:09", subseconds: "35", timeZone: utc))
        #expect(a < b)
        #expect(abs(b.timeIntervalSince(a) - 0.28) < 0.0001)
    }

    @Test func offsetOverridesTheMacZone() throws {
        let plus2 = try #require(CaptureTime.parse(dateTimeOriginal: "2026:09:30 14:05:09", offset: "+02:00", timeZone: utc))
        let none = try #require(CaptureTime.parse(dateTimeOriginal: "2026:09:30 14:05:09", timeZone: utc))
        #expect(none.timeIntervalSince(plus2) == 7200)
    }

    @Test func negativeOffset() throws {
        let minus = try #require(CaptureTime.parse(dateTimeOriginal: "2026:09:30 14:05:09", offset: "-03:30", timeZone: utc))
        let none = try #require(CaptureTime.parse(dateTimeOriginal: "2026:09:30 14:05:09", timeZone: utc))
        #expect(minus.timeIntervalSince(none) == 3.5 * 3600)
    }

    @Test(arguments: ["", "0000:00:00 00:00:00", "    :  :     :  :  ", "2026:09:30", "garbage", "2026:13:01 00:00:00"])
    func rejectsUnsetOrMalformed(_ text: String) {
        #expect(CaptureTime.parse(dateTimeOriginal: text, timeZone: utc) == nil)
    }

    @Test func badOffsetFallsBackToTheGivenZone() throws {
        let a = try #require(CaptureTime.parse(dateTimeOriginal: "2026:09:30 14:05:09", offset: "+99:00", timeZone: utc))
        let b = try #require(CaptureTime.parse(dateTimeOriginal: "2026:09:30 14:05:09", timeZone: utc))
        #expect(a == b)
    }

    @Test func missingFileHasNoTime() {
        #expect(CaptureTime.read(from: URL(fileURLWithPath: "/nonexistent/IMG_0001.ARW")) == nil)
    }
}
