// V-13 tool. Not shipped.
//   ExtractBench <folder or files...> [--exact] [--verify]
// Extracts every file's largest embedded JPEG into a new temporary folder, then copies that folder with `cp -R`
// (a real byte copy: the stand-in for Finder) and prints both times. The extraction must be within 20% of the copy.
// --out=DIR keeps the JPEGs there instead of a temporary folder.
// --verify compares each output with the reference extractor named in PREVIEW_ORACLE (identical bytes, or the same
// bytes plus zero padding), in exact mode only.
import Containers
import Foundation
import Library

var paths = Array(CommandLine.arguments.dropFirst())
let exact = paths.contains("--exact") || paths.contains("--verify")
let verify = paths.contains("--verify")
let keep = paths.first { $0.hasPrefix("--out=") }.map { URL(fileURLWithPath: String($0.dropFirst(6))) }
paths.removeAll { $0.hasPrefix("--") }
guard !paths.isEmpty else {
    FileHandle.standardError.write(Data("usage: ExtractBench <folder or files...> [--exact] [--verify]\n".utf8))
    exit(2)
}
if verify, ProcessInfo.processInfo.environment["PREVIEW_ORACLE"] == nil {
    FileHandle.standardError.write(Data("--verify needs PREVIEW_ORACLE=<path to the reference extractor>\n".utf8))
    exit(2)
}

var sources: [URL] = []
for path in paths {
    let url = URL(fileURLWithPath: path)
    var isDir: ObjCBool = false
    FileManager.default.fileExists(atPath: path, isDirectory: &isDir)
    if isDir.boolValue {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []
        sources += names.sorted().map { url.appendingPathComponent($0) }.filter {
            PhotoFormat(pathExtension: $0.pathExtension)?.isRaw == true
        }
    } else {
        sources.append(url)
    }
}

let work = FileManager.default.temporaryDirectory.appendingPathComponent("extract-bench-\(UUID().uuidString)")
let out = keep ?? work.appendingPathComponent("out"), copy = work.appendingPathComponent("copy")
try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: work) }

let clock = ContinuousClock()
func seconds(_ d: Duration) -> Double { Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18 }

var summary = EmbeddedJPEGExtractor.Summary()
let extractTime = clock.measure { summary = EmbeddedJPEGExtractor.run(sources, into: out, exactBytes: exact) }

let outFiles = (try? FileManager.default.contentsOfDirectory(atPath: out.path)) ?? []
let bytes = outFiles.reduce(0) { $0 + ((try? FileManager.default.attributesOfItem(atPath: out.appendingPathComponent($1).path)[.size] as? Int) ?? 0) }

let cp = Process()
cp.executableURL = URL(fileURLWithPath: "/bin/cp")
cp.arguments = ["-R", out.path, copy.path]
let copyTime = clock.measure { try? cp.run(); cp.waitUntilExit() }

let e = seconds(extractTime), c = seconds(copyTime)
print("files \(sources.count), written \(summary.written), no JPEG \(summary.withoutEmbeddedJPEG.count), not RAW \(summary.notRaw.count), failed \(summary.failed.count), EXIF added \(summary.exifAdded), renamed \(summary.renamed.count)")
print(String(format: "%.1f MB written", Double(bytes) / 1_048_576))
print(String(format: "extract %.3f s   cp -R of the same bytes %.3f s   ratio %.2f (limit 1.20)", e, c, c > 0 ? e / c : 0))
for f in summary.failed { print("FAILED \(f.name): \(f.detail)") }

if verify {
    func oracle(_ url: URL, group: String, tag: String) -> Data? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: ProcessInfo.processInfo.environment["PREVIEW_ORACLE"]!)
        p.arguments = ["-b", "-\(group):\(tag)", url.path]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return data.isEmpty ? nil : data
    }
    func same(_ theirs: Data, _ mine: Data) -> Bool {
        theirs == mine || (theirs.starts(with: mine) && theirs.dropFirst(mine.count).allSatisfy { $0 == 0 })
    }
    var bad = 0, checked = 0
    for source in sources where !summary.withoutEmbeddedJPEG.contains(source.lastPathComponent) {
        let stem = source.deletingPathExtension().lastPathComponent
        guard let mine = try? Data(contentsOf: out.appendingPathComponent("\(stem).jpg")),
              let found = try? PreviewLocator.locate(at: source), let best = found.largest else { continue }
        let groups = [best.location] + (["RAF": ["File"], "THMB": ["Canon"], "PRVW": ["QuickTime"]][best.location] ?? [])
        var ok = false
        search: for g in groups { for t in ["PreviewImage", "JpgFromRaw", "ThumbnailImage", "OtherImage"] {
            if let theirs = oracle(source, group: g, tag: t), same(theirs, mine) { ok = true; break search }
        } }
        checked += 1
        if !ok { bad += 1; print("DIFFERS \(source.lastPathComponent)") }
    }
    print("oracle: \(checked - bad) of \(checked) identical")
    if bad > 0 { exit(1) }
}
