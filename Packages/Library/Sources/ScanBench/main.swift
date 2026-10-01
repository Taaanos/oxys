import Foundation
import Library

// M-01 check: ScanBench <folder> [width]. Prints list time and capture-time time.
let arguments = CommandLine.arguments
guard arguments.count >= 2 else { print("usage: ScanBench <folder> [width...]"); exit(2) }
let folder = URL(fileURLWithPath: arguments[1])
let widths = arguments.dropFirst(2).compactMap(Int.init)

func seconds(_ body: () async throws -> Void) async rethrows -> Double {
    let start = ContinuousClock.now
    try await body()
    let d = ContinuousClock.now - start
    return Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
}

var photos: [Photo] = []
let listTime = try await seconds { photos = try FolderScanner.scan(folder).photos }
print(String(format: "list: %d files in %.3f s", photos.count, listTime))
for width in widths.isEmpty ? [8] : widths {
    var times: [Date?] = []
    let t = await seconds { times = await FolderScanner.captureTimes(for: photos, width: width) }
    print(String(format: "capture times, width %d: %d of %d found in %.3f s", width, times.compactMap { $0 }.count, photos.count, t))
}
