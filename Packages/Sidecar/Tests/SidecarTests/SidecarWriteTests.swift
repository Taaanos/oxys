import Foundation
import Testing
@testable import Sidecar

private let packageRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
private let fixtures = packageRoot.appendingPathComponent("Tests/Fixtures/xmp")
private let when = Date(timeIntervalSince1970: 1_790_000_000)

private func fixture(_ path: String) throws -> Data { try Data(contentsOf: fixtures.appendingPathComponent(path)) }

private func text(_ data: Data) -> String { String(decoding: data, as: UTF8.self) }

/// The text with our three properties (attributes and elements) cut out and whitespace dropped, so two packets
/// that differ only inside those properties compare equal.
private func stripped(_ s: String) -> String {
    var s = s
    for name in ["Rating", "Label", "MetadataDate"] {
        for pattern in [#"\s*[A-Za-z0-9]+:\#(name)\s*=\s*("[^"]*"|'[^']*')"#, #"\s*<[A-Za-z0-9]+:\#(name)\s*/>"#,
                        #"\s*<([A-Za-z0-9]+):\#(name)>[^<]*</\1:\#(name)>"#] {
            s = s.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
        }
    }
    // A declaration of the XMP namespace is the one other thing a patch may add.
    s = s.replacingOccurrences(of: #"\s*xmlns:xmp\d*="http://ns.adobe.com/xap/1.0/""#, with: "", options: .regularExpression)
    return s.replacingOccurrences(of: #"\s+"#, with: "", options: .regularExpression)
}

private let allFixtures = [
    "art-1.26.7/created-3star-red.xmp", "art-1.26.7/edited-5star-yellow.xmp", "art-1.26.7/trash-minus1-red.xmp",
    "art-1.26.7/cleared-0star-nolabel.xmp", "hand-written/attributes-4star-blue.xmp",
    "hand-written/elements-2star-green.xmp", "hand-written/xap-prefix-5star-yellow.xmp",
    "hand-written/multi-description-1star-red.xmp", "hand-written/reject-minus1.xmp",
    "hand-written/custom-label-select.xmp", "hand-written/other-namespace-ignored.xmp",
]

@Suite struct PatcherTests {
    @Test(arguments: allFixtures)
    func outputDiffersOnlyInOurProperties(path: String) throws {
        let input = try fixture(path)
        for edit in [SidecarEdit(rating: 3, label: .set("Red")), SidecarEdit(rating: 0, label: .remove),
                     SidecarEdit(rating: -1, label: .keep)] {
            let output = try XMPPatcher.patch(input, edit: edit, date: when)
            #expect(stripped(text(output)) == stripped(text(input)), "\(path) \(edit)")
            let props = try XMPReader.parse(output)
            #expect(props.rating == edit.rating)
            switch edit.label {
            case .set(let name): #expect(props.label == name)
            case .remove: #expect(props.label == nil)
            case .keep: #expect(props.label == (try XMPReader.parse(input)).label)
            }
        }
    }

    @Test func keepsEveryOtherByteOfAForeignPacket() throws {
        let input = try fixture("hand-written/multi-description-1star-red.xmp")
        let output = try XMPPatcher.patch(input, edit: SidecarEdit(rating: 4, label: .set("Blue")), date: when)
        let expected = text(input)
            .replacingOccurrences(of: #"a:Rating="1""#, with: #"a:Rating="4""#)
            .replacingOccurrences(of: "<b:Label>Red</b:Label>", with: "<b:Label>Blue</b:Label>")
        // The only addition is the date, inserted on the Description that has the XMP namespace in scope.
        #expect(text(output).contains("crs:Exposure2012=\"+0.50\"/>"))
        #expect(text(output).replacingOccurrences(of: #" a:MetadataDate="[^"]*""#, with: "", options: .regularExpression) == expected)
    }

    @Test func replacesValuesInPlaceWithoutReformatting() throws {
        let input = try fixture("hand-written/attributes-4star-blue.xmp")
        let output = text(try XMPPatcher.patch(input, edit: SidecarEdit(rating: 2, label: .set("Green")), date: when))
        #expect(output.contains(#"xmp:Rating="2" xmp:Label="Green""#))
        #expect(output.hasPrefix("<?xpacket begin"))
        #expect(output.hasSuffix("<?xpacket end=\"w\"?>\n"))
    }

    @Test func removesAnElementFormLabelAndItsLine() throws {
        let input = try fixture("hand-written/elements-2star-green.xmp")
        let output = text(try XMPPatcher.patch(input, edit: SidecarEdit(rating: 2, label: .remove), date: when))
        #expect(!output.contains("Label"))
        #expect(output.contains("<xmp:Rating>2</xmp:Rating>"))
        #expect(!output.contains("\n\n"))
    }

    @Test func createsAPacketFromTheTemplate() throws {
        let output = try XMPPatcher.patch(nil, edit: SidecarEdit(rating: 3, label: .set("Red")), date: when)
        let props = try XMPReader.parse(output)
        #expect(props == XMPProperties(rating: 3, label: "Red"))
        #expect(text(output).contains("xmp:MetadataDate="))
    }

    @Test func declaresTheNamespaceWhenNoDescriptionHasIt() throws {
        let input = Data(#"<x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#"><rdf:Description rdf:about="" xmlns:crs="http://ns.adobe.com/camera-raw-settings/1.0/" crs:Exposure2012="+0.50"/></rdf:RDF></x:xmpmeta>"#.utf8)
        let output = try XMPPatcher.patch(input, edit: SidecarEdit(rating: 5, label: .keep), date: when)
        #expect(try XMPReader.parse(output).rating == 5)
        #expect(text(output).contains(#"crs:Exposure2012="+0.50""#))
    }

    @Test func addsADescriptionWhenThereIsNone() throws {
        let input = Data(#"<x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#"></rdf:RDF></x:xmpmeta>"#.utf8)
        let output = try XMPPatcher.patch(input, edit: SidecarEdit(rating: 1, label: .set("Blue")), date: when)
        #expect(try XMPReader.parse(output) == XMPProperties(rating: 1, label: "Blue"))
    }

    @Test func refusesWhatItCannotPatch() throws {
        #expect(throws: XMPPatchError.self) { try XMPPatcher.patch(Data("<a><b></a>".utf8), edit: SidecarEdit(rating: 1, label: .keep), date: when) }
        #expect(throws: XMPPatchError.self) { try XMPPatcher.patch(Data("<?xml version=\"1.0\"?><!DOCTYPE x><x/>".utf8), edit: SidecarEdit(rating: 1, label: .keep), date: when) }
        #expect(throws: XMPPatchError.self) { try XMPPatcher.patch("<a/>".data(using: .utf16), edit: SidecarEdit(rating: 1, label: .keep), date: when) }
    }

    @Test func metadataDateIsISO8601WithAnOffset() {
        #expect(XMPPatcher.metadataDate(when).wholeMatch(of: #/\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d[+-]\d\d:\d\d/#) != nil)
    }
}

@Suite struct WriterTests {
    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("oxys-w-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func createsThenPatchesAndKeepsPermissions() throws {
        let dir = try folder(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("a.xmp")
        let target = SidecarTarget(primary: url)
        #expect(SidecarWriter.write(SidecarEdit(rating: 3, label: .set("Red")), to: target) == .written(url))
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        #expect(SidecarWriter.write(SidecarEdit(rating: 4, label: .remove), to: target) == .written(url))
        #expect(try XMPReader.parse(Data(contentsOf: url)) == XMPProperties(rating: 4, label: nil))
        let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        #expect(mode?.intValue == 0o600)
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == ["a.xmp"])
    }

    @Test func readsTheFileJustBeforeWriting() throws {
        let dir = try folder(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("a.xmp")
        let target = SidecarTarget(primary: url)
        _ = SidecarWriter.write(SidecarEdit(rating: 3, label: .set("Red")), to: target)
        // Another program adds develop settings in between.
        var text = String(decoding: try Data(contentsOf: url), as: UTF8.self)
        text = text.replacingOccurrences(of: "<rdf:Description ", with: #"<rdf:Description xmlns:crs="http://ns.adobe.com/camera-raw-settings/1.0/" crs:Exposure2012="+1.00" "#)
        try Data(text.utf8).write(to: url)
        _ = SidecarWriter.write(SidecarEdit(rating: 5, label: .keep), to: target)
        let out = String(decoding: try Data(contentsOf: url), as: UTF8.self)
        #expect(out.contains(#"crs:Exposure2012="+1.00""#))
        #expect(try XMPReader.parse(Data(out.utf8)) == XMPProperties(rating: 5, label: "Red"))
    }

    @Test func refusesAMalformedSidecarAndLeavesItAlone() throws {
        let dir = try folder(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("a.xmp")
        let bad = Data("<rdf:RDF".utf8)
        try bad.write(to: url)
        guard case .refused = SidecarWriter.write(SidecarEdit(rating: 3, label: .keep), to: SidecarTarget(primary: url)) else {
            Issue.record("expected a refusal"); return
        }
        #expect(try Data(contentsOf: url) == bad)
    }

    @Test func fallbackIsPatchedWhenPrimaryDoesNotExist() throws {
        let dir = try folder(); defer { try? FileManager.default.removeItem(at: dir) }
        let primary = dir.appendingPathComponent("a.xmp"), other = dir.appendingPathComponent("a.ARW.xmp")
        try fixture("hand-written/attributes-4star-blue.xmp").write(to: other)
        let outcome = SidecarWriter.write(SidecarEdit(rating: 1, label: .keep), to: SidecarTarget(primary: primary, fallback: other))
        #expect(outcome == .written(other))
        #expect(!FileManager.default.fileExists(atPath: primary.path))
    }

    @Test func removesOnlyStaleTemps() throws {
        let dir = try folder(); defer { try? FileManager.default.removeItem(at: dir) }
        let stale = dir.appendingPathComponent(".a.xmp\(SidecarWriter.tempMarker)1"), fresh = dir.appendingPathComponent(".b.xmp\(SidecarWriter.tempMarker)2")
        for url in [stale, fresh] { try Data("x".utf8).write(to: url) }
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-3600)], ofItemAtPath: stale.path)
        #expect(SidecarWriter.removeStaleTemps(in: dir) == 1)
        #expect(FileManager.default.fileExists(atPath: fresh.path))
    }

    @Test func killingTheWriterMidWriteLeavesAWholeSidecar() throws {
        let tool = packageRoot.appendingPathComponent(".build/debug/SidecarStress")
        try #require(FileManager.default.isExecutableFile(atPath: tool.path), "build SidecarStress first (swift build)")
        let dir = try folder(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("a.xmp")
        _ = SidecarWriter.write(SidecarEdit(rating: 1, label: .set("Red")), to: SidecarTarget(primary: url))
        let valid: Set<XMPProperties> = Set((0..<5).map { XMPProperties(rating: $0 + 1, label: ["Red", "Yellow", "Green", "Blue", "Purple"][$0]) })
        for round in 0..<25 {
            let child = Process()
            child.executableURL = tool
            child.arguments = ["crashloop", url.path]
            try child.run()
            Thread.sleep(forTimeInterval: 0.05 + Double(round % 5) * 0.03)
            kill(child.processIdentifier, SIGKILL)
            child.waitUntilExit()
            let props = try XMPReader.parse(Data(contentsOf: url))
            #expect(valid.contains(props), "round \(round): \(props)")
        }
        SidecarWriter.removeStaleTemps(in: dir, olderThan: 0)
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == ["a.xmp"])
    }
}

@Suite struct QueueTests {
    @Test func aThousandDecisionsAllLand() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("oxys-q-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let queue = SidecarWriteQueue()
        var last: [Int: Int] = [:]
        for n in 0..<1000 {
            let photo = n % 25, rating = n % 6
            queue.submit(SidecarEdit(rating: rating, label: .keep), to: SidecarTarget(primary: dir.appendingPathComponent("p\(photo).xmp")))
            last[photo] = rating
        }
        queue.flush()
        for (photo, rating) in last {
            #expect(try XMPReader.parse(Data(contentsOf: dir.appendingPathComponent("p\(photo).xmp"))).rating == rating)
        }
    }

    @Test func submitDoesNotWaitForTheDisk() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("oxys-q-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let queue = SidecarWriteQueue()
        let start = ContinuousClock.now
        for n in 0..<200 { queue.submit(SidecarEdit(rating: n % 6, label: .keep), to: SidecarTarget(primary: dir.appendingPathComponent("p.xmp"))) }
        #expect(ContinuousClock.now - start < .milliseconds(50))
        queue.flush()
    }
}

@Suite struct WriteFailureQueueTests {
    @Test func aFailedWriteIsKeptAndRetriedLater() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("oxys-q-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { chmod(dir.path, 0o755); try? FileManager.default.removeItem(at: dir) }
        chmod(dir.path, 0o555)
        let queue = SidecarWriteQueue()
        let target = SidecarTarget(primary: dir.appendingPathComponent("a.xmp"))
        queue.submit(SidecarEdit(rating: 2, label: .remove), to: target)
        queue.flush()
        #expect(queue.unsavedCount == 1)
        #expect(queue.retryFailed() == 1)
        queue.flush()
        #expect(queue.unsavedCount == 1)
        chmod(dir.path, 0o755)
        queue.retryFailed(); queue.flush()
        #expect(queue.unsavedCount == 0)
        #expect(FileManager.default.fileExists(atPath: target.primary.path))
    }
}
