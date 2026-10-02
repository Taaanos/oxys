import Foundation
import Sidecar
import Synchronization

// M-08 tool.
//   SidecarStress crashloop <file>           writes forever; the test SIGKILLs it mid-write.
//   SidecarStress stress [seconds] [count]   `count` decisions spread over `seconds`, then checks every sidecar.
//   SidecarStress gate <seed.xmp> [count]    M-25: `count` writes in rounds; between rounds an outside program edits
//                                            sidecars and a writer process is killed mid-write. Checks that every
//                                            sidecar parses and keeps its foreign data.

let labels = ["Red", "Yellow", "Green", "Blue", "Purple"]
let args = CommandLine.arguments

switch args.dropFirst().first {
case "crashloop":
    let target = SidecarTarget(primary: URL(fileURLWithPath: args[2]))
    var n = 0
    while true {
        let edit = SidecarEdit(rating: n % 5 + 1, label: .set(labels[n % 5]))
        _ = SidecarWriter.write(edit, to: target)
        n += 1
    }
case "stress":
    let seconds = args.count > 2 ? Double(args[2]) ?? 60 : 60
    let count = args.count > 3 ? Int(args[3]) ?? 1000 : 1000
    let photos = 40
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("oxys-stress-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let queue = SidecarWriteQueue()
    var expected: [Int: SidecarEdit] = [:]
    let start = Date()
    for n in 0..<count {
        let photo = Int.random(in: 0..<photos)
        let edit = SidecarEdit(rating: Int.random(in: -1...5), label: Bool.random() ? .set(labels.randomElement()!) : .remove)
        queue.submit(edit, to: SidecarTarget(primary: folder.appendingPathComponent("IMG_\(photo).xmp")))
        expected[photo] = edit
        let due = start.addingTimeInterval(seconds * Double(n + 1) / Double(count))
        Thread.sleep(forTimeInterval: max(0, due.timeIntervalSinceNow))
    }
    queue.flush()
    var wrong = 0
    for (photo, edit) in expected {
        let url = folder.appendingPathComponent("IMG_\(photo).xmp")
        let props = try? XMPReader.parse(Data(contentsOf: url))
        var want = XMPProperties(rating: edit.rating)
        if case .set(let name) = edit.label { want.label = name }
        if props != want { wrong += 1; print("WRONG IMG_\(photo): \(String(describing: props)) want \(want)") }
    }
    let leftovers = ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).filter { $0.contains(SidecarWriter.tempMarker) }
    print("\(count) decisions in \(Int(Date().timeIntervalSince(start))) s, \(expected.count) sidecars, \(wrong) wrong, \(leftovers.count) temp files left")
    exit(wrong == 0 && leftovers.isEmpty ? 0 : 1)
case "gate":
    exit(runGate(seed: URL(fileURLWithPath: args[2]), count: args.count > 3 ? Int(args[3]) ?? 10_000 : 10_000))
default:
    print("usage: SidecarStress crashloop <file> | stress [seconds] [count] | gate <seed.xmp> [count]")
    exit(2)
}

// MARK: gate

/// The text with whitespace dropped and our three properties cut out (as in the patcher tests). Whitespace goes
/// first: it makes the patterns short and keeps the regex engine away from the packet's padding.
func foreignPart(_ data: Data) -> String {
    var s = String(decoding: data, as: UTF8.self).filter { !$0.isWhitespace }
    for name in ["Rating", "Label", "MetadataDate"] {
        for pattern in [#"[A-Za-z0-9]+:\#(name)=("[^"]*"|'[^']*')"#, #"<[A-Za-z0-9]+:\#(name)/>"#] {
            s = s.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
        }
    }
    return s
}

/// What a program that is not Oxys does to a sidecar: changes a Camera Raw value and sometimes the rating and
/// label, then replaces the file atomically (temporary file and rename), as Lightroom and ART do.
func outsideEdit(_ url: URL, exposure: String, rating: Int?, label: String?) throws -> Data {
    var text = String(decoding: try Data(contentsOf: url), as: UTF8.self)
    text = text.replacingOccurrences(of: #"crs:Exposure2012="[^"]*""#, with: "crs:Exposure2012=\"\(exposure)\"", options: .regularExpression)
    if let rating {
        text = text.replacingOccurrences(of: #"\s*xmp:Label="[^"]*""#, with: "", options: .regularExpression)
        let labelText = label.map { "\n   xmp:Label=\"\($0)\"" } ?? ""
        text = text.replacingOccurrences(of: #"xmp:Rating="[^"]*""#, with: "xmp:Rating=\"\(rating)\"" + labelText, options: .regularExpression)
    }
    let data = Data(text.utf8)
    let temp = url.deletingLastPathComponent().appendingPathComponent(".outside-\(UUID().uuidString.prefix(8))")
    try data.write(to: temp)
    guard rename(temp.path, url.path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    return data
}

func runGate(seed: URL, count: Int) -> Int32 {
    let photos = 40, perRound = 500
    let me = URL(fileURLWithPath: CommandLine.arguments[0])
    guard let seedData = try? Data(contentsOf: seed) else { print("cannot read \(seed.path)"); return 2 }
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("oxys-gate-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    func url(_ photo: Int) -> URL { folder.appendingPathComponent("IMG_\(photo).xmp") }
    for photo in 0..<photos { try? seedData.write(to: url(photo)) }

    // Every decision is flushed on its own, so each one is a real file write (the queue merges pending edits).
    let diskWrites = Mutex(0)
    let queue = SidecarWriteQueue(onOutcome: { if case .written = $0 { diskWrites.withLock { $0 += 1 } } })
    var expected: [Int: XMPProperties?] = [:]          // nil value: unknown after a crash, until the next write
    var foreign: [Int: String] = [:]
    for photo in 0..<photos { foreign[photo] = foreignPart(seedData) }
    var wrong = 0, lostForeign = 0, unparsable = 0, writes = 0, outside = 0, crashes = 0
    let valid: Set<XMPProperties> = Set((0..<5).map { XMPProperties(rating: $0 + 1, label: labels[$0]) })

    func check(_ photo: Int, _ context: String) {
        guard let data = try? Data(contentsOf: url(photo)), let props = try? XMPReader.parse(data) else {
            unparsable += 1; print("UNPARSABLE IMG_\(photo) \(context)"); return
        }
        if foreignPart(data) != foreign[photo] { lostForeign += 1; print("FOREIGN DATA CHANGED IMG_\(photo) \(context)") }
        switch expected[photo] {
        case .some(.some(let want)):
            if props != want { wrong += 1; print("WRONG IMG_\(photo) \(context): \(props) want \(want)") }
        default:
            if !valid.contains(props) { wrong += 1; print("WRONG IMG_\(photo) \(context): \(props) is not a crash-loop value") }
        }
    }

    var round = 0
    while writes < count {
        round += 1
        for _ in 0..<min(perRound, count - writes) {
            let photo = Int.random(in: 0..<photos)
            let edit = SidecarEdit(rating: Int.random(in: -1...5), label: Bool.random() ? .set(labels.randomElement()!) : .remove)
            queue.submit(edit, to: SidecarTarget(primary: url(photo)))
            queue.flush()
            var want = XMPProperties(rating: edit.rating)
            if case .set(let name) = edit.label { want.label = name }
            expected[photo] = .some(want)
            writes += 1
        }
        queue.flush()
        for photo in 0..<photos { check(photo, "round \(round) after queue") }

        // Outside writers: a few sidecars get a new Camera Raw value, some also a new rating and label.
        for photo in (0..<photos).shuffled().prefix(8) {
            let exposure = String(format: "%+.2f", Double.random(in: -2...2))
            let change = Bool.random()
            let rating = change ? Int.random(in: 0...5) : nil
            let label = change && Bool.random() ? labels.randomElement()! : nil
            guard let data = try? outsideEdit(url(photo), exposure: exposure, rating: rating, label: label) else { continue }
            outside += 1
            foreign[photo] = foreignPart(data)
            if let rating { var want = XMPProperties(rating: rating); want.label = label; expected[photo] = .some(want) }
        }
        // The next queue write must start from the outside program's file: write one decision to every sidecar.
        for photo in 0..<photos {
            queue.submit(SidecarEdit(rating: 2, label: .keep), to: SidecarTarget(primary: url(photo)))
            writes += 1
            if case .some(.some(var want)) = expected[photo] { want.rating = 2; expected[photo] = .some(want) } else { expected[photo] = .some(XMPProperties(rating: 2)) }
        }
        queue.flush()
        for photo in 0..<photos { check(photo, "round \(round) after outside edit") }

        // A writer process killed mid-write, on a photo that has outside data.
        let victim = Int.random(in: 0..<photos)
        let child = Process()
        child.executableURL = me
        child.arguments = ["crashloop", url(victim).path]
        child.standardOutput = FileHandle.nullDevice
        if (try? child.run()) != nil {
            Thread.sleep(forTimeInterval: Double.random(in: 0.02...0.12))
            kill(child.processIdentifier, SIGKILL)
            child.waitUntilExit()
            crashes += 1
            expected[victim] = .some(nil)
            check(victim, "round \(round) after kill")
            SidecarWriter.removeStaleTemps(in: folder, olderThan: 0)
        }
    }
    queue.flush()
    SidecarWriter.removeStaleTemps(in: folder, olderThan: 0)
    let leftovers = ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).filter { $0.hasPrefix(".") }
    print("\(writes) decisions, \(diskWrites.withLock { $0 }) file writes, \(outside) outside edits, \(crashes) killed writers, \(photos) sidecars: \(unparsable) unparsable, \(lostForeign) with changed foreign data, \(wrong) wrong decisions, \(leftovers.count) temp files left")
    return unparsable == 0 && lostForeign == 0 && wrong == 0 && leftovers.isEmpty ? 0 : 1
}
