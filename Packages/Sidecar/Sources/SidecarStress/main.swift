import Foundation
import Sidecar

// M-08 tool.
//   SidecarStress crashloop <file>           writes forever; the test SIGKILLs it mid-write.
//   SidecarStress stress [seconds] [count]   `count` decisions spread over `seconds`, then checks every sidecar.

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
default:
    print("usage: SidecarStress crashloop <file> | stress [seconds] [count]")
    exit(2)
}
