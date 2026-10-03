import Darwin
import Foundation
import Imaging
import Testing
@testable import Library

private func scratch() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("export-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func names(_ folder: URL) -> [String] {
    ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).sorted()
}

@Test func safeWriteNeverOverwritesAndNamesTheSuffix() throws {
    let dir = try scratch(), out = try scratch()
    defer { try? FileManager.default.removeItem(at: dir); try? FileManager.default.removeItem(at: out) }
    let source = dir.appendingPathComponent("A.ARW")
    try Data("raw".utf8).write(to: source)
    let first = try SafeWrite.place(Data("one".utf8), in: out, stem: "A", ext: "heic", attributesFrom: source)
    let second = try SafeWrite.place(Data("two".utf8), in: out, stem: "A", ext: "heic", attributesFrom: source)
    #expect(first.output.lastPathComponent == "A.heic" && !first.renamed)
    #expect(second.output.lastPathComponent == "A-1.heic" && second.renamed)
    #expect(try Data(contentsOf: first.output) == Data("one".utf8))
    #expect(names(out) == ["A-1.heic", "A.heic"])      // no temporary file is left
}

@Test func safeWriteCopiesDatesPermissionsAndExtendedAttributes() throws {
    let dir = try scratch(), out = try scratch()
    defer { try? FileManager.default.removeItem(at: dir); try? FileManager.default.removeItem(at: out) }
    let source = dir.appendingPathComponent("A.ARW")
    try Data("raw".utf8).write(to: source)
    let created = Date(timeIntervalSince1970: 1_500_000_000), modified = Date(timeIntervalSince1970: 1_600_000_000)
    try FileManager.default.setAttributes([.creationDate: created, .modificationDate: modified, .posixPermissions: 0o600], ofItemAtPath: source.path)
    #expect(setxattr(source.path, "com.apple.metadata:test", "tag", 3, 0, 0) == 0)

    let placed = try SafeWrite.place(Data("x".utf8), in: out, stem: "A", ext: "jpg", attributesFrom: source)
    #expect(placed.warnings.isEmpty)
    let attributes = try FileManager.default.attributesOfItem(atPath: placed.output.path)
    #expect(attributes[.creationDate] as? Date == created)
    #expect(attributes[.modificationDate] as? Date == modified)
    #expect(attributes[.posixPermissions] as? Int == 0o600)
    var buffer = [UInt8](repeating: 0, count: 8)
    #expect(getxattr(placed.output.path, "com.apple.metadata:test", &buffer, 8, 0, 0) == 3)
}

@Test func aJPEGOriginalIsNotRawAndATextFileCannotBeDeveloped() throws {
    let dir = try scratch(), out = try scratch()
    defer { try? FileManager.default.removeItem(at: dir); try? FileManager.default.removeItem(at: out) }
    let jpeg = dir.appendingPathComponent("A.jpg")
    let broken = dir.appendingPathComponent("B.dng")
    try Data("not an image".utf8).write(to: jpeg)
    try Data("not a raw".utf8).write(to: broken)
    let renderer = DevelopedRenderer()
    #expect(throws: ExportFailure.notRaw) { try DevelopedExporter.export(jpeg, into: out, as: .jpeg, renderer: renderer) }
    do {
        _ = try DevelopedExporter.export(broken, into: out, as: .heic, renderer: renderer)
        Issue.record("a broken RAW was written")
    } catch ExportFailure.cannotDevelop {
    }
    #expect(names(out).isEmpty)
}

@Test func theSummaryListsWhatCouldNotBeDevelopedAndLeavesNoFile() throws {
    let dir = try scratch(), out = try scratch()
    defer { try? FileManager.default.removeItem(at: dir); try? FileManager.default.removeItem(at: out) }
    let jpeg = dir.appendingPathComponent("A.jpg"), broken = dir.appendingPathComponent("B.dng")
    try Data("x".utf8).write(to: jpeg)
    try Data("x".utf8).write(to: broken)
    let summary = DevelopedExporter.run([jpeg, broken], into: out, as: .jpeg)
    #expect(summary.total == 2 && summary.written == 0)
    #expect(summary.notRaw == ["A.jpg"])
    #expect(summary.couldNotDevelop.map(\.name) == ["B.dng"])
    #expect(summary.hasProblems && !summary.cancelled)
    #expect(summary.destination == out)
    #expect(names(out).isEmpty)
}

@Test func cancelBeforeTheFirstFileDoesNothingAndSaysSo() throws {
    let dir = try scratch(), out = try scratch()
    defer { try? FileManager.default.removeItem(at: dir); try? FileManager.default.removeItem(at: out) }
    let broken = dir.appendingPathComponent("B.dng")
    try Data("x".utf8).write(to: broken)
    let summary = DevelopedExporter.run([broken], into: out, as: .heic, isCancelled: { true })
    #expect(summary.cancelled && summary.written == 0 && summary.couldNotDevelop.isEmpty)
    #expect(names(out).isEmpty)
}

@Test func theFormatsKnowTheirExtensionAndWhichAreDeveloped() {
    #expect(ExportFormat.allCases.map(\.fileExtension) == ["jpg", "jpg", "heic"])
    #expect(!ExportFormat.embeddedJPEG.isDeveloped && ExportFormat.developedJPEG.isDeveloped && ExportFormat.developedHEIC.isDeveloped)
}
