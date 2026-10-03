import Foundation
import Testing
@testable import Containers

/// A disk image, mounted like a card: local, ejectable and not internal. It is the volume we pull out in the tests (B-3).
private final class CardImage {
    let mountPoint: URL
    private let folder: URL
    private var device: String?

    init() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("oxys-card-\(UUID().uuidString)")
        mountPoint = folder.appendingPathComponent("mount")
        try FileManager.default.createDirectory(at: mountPoint, withIntermediateDirectories: true)
        let image = folder.appendingPathComponent("card.dmg")
        try Self.hdiutil(["create", "-size", "16m", "-fs", "APFS", "-volname", "OxysCard", "-type", "UDIF", image.path])
        let output = try Self.hdiutil(["attach", image.path, "-nobrowse", "-mountpoint", mountPoint.path])
        device = output.split(separator: "\n").first.flatMap { $0.split(whereSeparator: \.isWhitespace).first }.map(String.init)
    }

    /// Pulls the card: a forced detach, with no unmount first.
    func pull() throws {
        guard let device else { return }
        self.device = nil
        try Self.hdiutil(["detach", device, "-force"])
    }

    deinit {
        if let device { _ = try? Self.hdiutil(["detach", device, "-force"]) }
        try? FileManager.default.removeItem(at: folder)
    }

    @discardableResult
    private static func hdiutil(_ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = arguments
        // hdiutil prints a deprecation notice on stderr; only stdout carries the device list.
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let errorText = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw CardError(message: "hdiutil \(arguments.first ?? ""): \(errorText)") }
        return text
    }
}

private struct CardError: Error, CustomStringConvertible { let message: String; var description: String { message } }

@Suite struct FileBytesTests {
    @Test func aFileOnTheInternalDiskIsMapped() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("oxys-fb-\(UUID().uuidString)")
        try Data(repeating: 7, count: 4096).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(FileBytes.isSafeToMap(url))
        #expect(try FileBytes.load(url) == Data(repeating: 7, count: 4096))
    }

    @Test func aFileOnACardIsNotMapped() throws {
        let card = try CardImage()
        let url = card.mountPoint.appendingPathComponent("IMG_0001.ARW")
        try Data(repeating: 9, count: 4096).write(to: url)
        #expect(!FileBytes.isSafeToMap(url))
        #expect(try FileBytes.load(url) == Data(repeating: 9, count: 4096))
    }

    @Test func aMissingFileThrows() {
        #expect(throws: (any Error).self) { try FileBytes.load(URL(fileURLWithPath: "/nonexistent/oxys/IMG.ARW")) }
        #expect(!FileBytes.isSafeToMap(URL(fileURLWithPath: "/nonexistent/oxys/IMG.ARW")))
    }

    /// The bytes stay valid after the card is pulled. With a mapping, touching them would raise SIGBUS and end the test process.
    @Test func theBytesOutliveThePulledCard() throws {
        let card = try CardImage()
        let url = card.mountPoint.appendingPathComponent("IMG_0001.ARW")
        let content = Data((0..<(8 << 20)).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        try content.write(to: url)
        let loaded = try FileBytes.load(url)
        try card.pull()
        var sum = 0
        loaded.withUnsafeBytes { for byte in $0 { sum &+= Int(byte) } }
        #expect(sum == content.reduce(0) { $0 &+ Int($1) })
        #expect(loaded == content)
        #expect(throws: (any Error).self) { try FileBytes.load(url) }
    }

    @Test func locatingOnAPulledCardThrowsInsteadOfCrashing() throws {
        let card = try CardImage()
        let url = card.mountPoint.appendingPathComponent("IMG_0001.ARW")
        try Data(repeating: 1, count: 1 << 20).write(to: url)
        try card.pull()
        #expect(throws: (any Error).self) { _ = try PreviewLocator.locate(at: url) }
    }
}
