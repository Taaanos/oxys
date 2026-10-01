import Foundation
import Testing
@testable import Sidecar

private let fixtures = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures/xmp")

private func parse(_ path: String) throws -> XMPProperties {
    try XMPReader.parse(Data(contentsOf: fixtures.appendingPathComponent(path)))
}

@Test(arguments: [
    ("art-1.26.7/created-3star-red.xmp", XMPProperties(rating: 3, label: "Red")),
    ("art-1.26.7/edited-5star-yellow.xmp", XMPProperties(rating: 5, label: "Yellow")),
    ("art-1.26.7/trash-minus1-red.xmp", XMPProperties(rating: -1, label: "Red")),
    ("art-1.26.7/cleared-0star-nolabel.xmp", XMPProperties(rating: 0, label: nil)),
    ("hand-written/attributes-4star-blue.xmp", XMPProperties(rating: 4, label: "Blue")),
    ("hand-written/elements-2star-green.xmp", XMPProperties(rating: 2, label: "Green")),
    ("hand-written/xap-prefix-5star-yellow.xmp", XMPProperties(rating: 5, label: "Yellow")),
    ("hand-written/multi-description-1star-red.xmp", XMPProperties(rating: 1, label: "Red")),
    ("hand-written/reject-minus1.xmp", XMPProperties(rating: -1, label: nil)),
    ("hand-written/custom-label-select.xmp", XMPProperties(rating: 3, label: "Select")),
    ("hand-written/other-namespace-ignored.xmp", XMPProperties()),
])
func fixtureParses(path: String, expected: XMPProperties) throws {
    #expect(try parse(path) == expected)
}

@Test func malformedFixtureThrows() {
    #expect(throws: XMPParseError.self) { try parse("hand-written/malformed-truncated.xmp") }
}

@Test func nonXMPThrows() {
    #expect(throws: XMPParseError.self) { try XMPReader.parse(Data("<html/>".utf8)) }
    #expect(throws: XMPParseError.self) { try XMPReader.parse(Data()) }
}

@Test func ratingIsClampedAndGarbageIgnored() throws {
    let xml = """
    <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#"><rdf:Description xmlns:xmp="http://ns.adobe.com/xap/1.0/" xmp:Rating="9"/></rdf:RDF>
    """
    #expect(try XMPReader.parse(Data(xml.utf8)).rating == 5)
    let bad = xml.replacingOccurrences(of: "\"9\"", with: "\"3.5\"")
    #expect(try XMPReader.parse(Data(bad.utf8)).rating == nil)
}

@Test func namingStyles() {
    #expect(SidecarNaming.stem.fileName(for: "IMG_1.ARW") == "IMG_1.xmp")
    #expect(SidecarNaming.fullName.fileName(for: "IMG_1.ARW") == "IMG_1.ARW.xmp")
}

private func makeFolder(_ files: [String: String]) throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("oxys-sidecar-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    for (name, text) in files { try Data(text.utf8).write(to: dir.appendingPathComponent(name)) }
    return dir
}

private let ratedXMP = """
<rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#"><rdf:Description xmlns:xmp="http://ns.adobe.com/xap/1.0/" xmp:Rating="%d"/></rdf:RDF>
"""

@Test func locatorPrefersConfiguredStyleAndReportsTheOther() throws {
    let dir = try makeFolder(["A.xmp": "", "A.ARW.xmp": "", "B.ARW.xmp": "", "C.xmp": "", "A.ARW.arp": ""])
    defer { try? FileManager.default.removeItem(at: dir) }
    let index = SidecarIndex(folder: dir)
    let a = dir.appendingPathComponent("A.ARW")
    #expect(index.files(for: a, preferring: .stem)?.primary.lastPathComponent == "A.xmp")
    #expect(index.files(for: a, preferring: .stem)?.alsoPresent?.lastPathComponent == "A.ARW.xmp")
    #expect(index.files(for: a, preferring: .fullName)?.primary.lastPathComponent == "A.ARW.xmp")
    // Falls back to the other style; `.arp` files are never sidecars.
    #expect(index.files(for: dir.appendingPathComponent("B.ARW"), preferring: .stem)?.primary.lastPathComponent == "B.ARW.xmp")
    #expect(index.files(for: dir.appendingPathComponent("C.CR3"), preferring: .fullName)?.primary.lastPathComponent == "C.xmp")
    #expect(index.files(for: dir.appendingPathComponent("D.ARW"), preferring: .stem) == nil)
}

@Test func readerResults() throws {
    let dir = try makeFolder(["A.xmp": String(format: ratedXMP, 4), "B.xmp": "<rdf:RDF"])
    defer { try? FileManager.default.removeItem(at: dir) }
    let index = SidecarIndex(folder: dir)
    let a = SidecarReader.read(photo: dir.appendingPathComponent("A.ARW"), embeddedFallback: false, index: index, naming: .stem)
    guard case .sidecar(_, let props) = a else { Issue.record("expected sidecar, got \(a)"); return }
    #expect(props.rating == 4)
    let b = SidecarReader.read(photo: dir.appendingPathComponent("B.ARW"), embeddedFallback: false, index: index, naming: .stem)
    guard case .malformed(let files, _) = b else { Issue.record("expected malformed, got \(b)"); return }
    #expect(files.primary.lastPathComponent == "B.xmp")
    #expect(SidecarReader.read(photo: dir.appendingPathComponent("Z.ARW"), embeddedFallback: false, index: index, naming: .stem) == .none)
}

@Test func fiveThousandSidecarsReadQuickly() throws {
    var files: [String: String] = [:]
    for i in 0..<5000 { files["IMG_\(i).xmp"] = String(format: ratedXMP, i % 6) }
    let dir = try makeFolder(files)
    defer { try? FileManager.default.removeItem(at: dir) }
    let start = ContinuousClock.now
    let index = SidecarIndex(folder: dir)
    var total = 0
    for i in 0..<5000 {
        if case .sidecar(_, let p) = SidecarReader.read(photo: dir.appendingPathComponent("IMG_\(i).ARW"), embeddedFallback: false, index: index, naming: .stem) {
            total += p.rating ?? 0
        }
    }
    let elapsed = ContinuousClock.now - start
    print("5000 sidecars serially: \(elapsed)")
    #expect(total == 5000 / 6 * 15 + (0..<(5000 % 6)).reduce(0, +))
    #expect(elapsed < .seconds(5))
}
