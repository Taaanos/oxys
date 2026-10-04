// V-13 tool. Not shipped.
//   ExtractBench <folder or files...> [--exact] [--verify] [--developed=jpeg|heic] [--quality=0.9] [--private] [--limit=N]
// Extracts every file's largest embedded JPEG into a new temporary folder, then copies that folder with `cp -R`
// (a real byte copy: the stand-in for Finder) and prints both times. The extraction must be within 20% of the copy.
// --out=DIR keeps the JPEGs there instead of a temporary folder.
// --limit=N takes the first N files of the list (P-10: the criterion is 500 files).
// --verify compares each output with the reference extractor named in PREVIEW_ORACLE (identical bytes, or the same
// bytes plus zero padding), in exact mode only.
// --developed=jpeg|heic (V-21) develops every RAW at the decoder's defaults instead, one at a time, prints the time
// per file, and checks each output against its source: Exif and GPS values, size, orientation, depth, profile, and
// the file's dates, permissions and extended attributes. No oracle is needed. Exit 1 on a difference.
// --private (V-22) writes with "remove location and serial numbers" on, then reads every output with ImageIO (and with
// the reference reader of PREVIEW_ORACLE, if it is set) and fails if any GPS, serial, owner or maker note field is left.
// It also prints how many of the sources had such fields, so that a pass on files with none means nothing.
import Containers
import Foundation
import ImageIO
import Imaging
import Library

var paths = Array(CommandLine.arguments.dropFirst())
let exact = paths.contains("--exact") || paths.contains("--verify")
let verify = paths.contains("--verify")
let keep = paths.first { $0.hasPrefix("--out=") }.map { URL(fileURLWithPath: String($0.dropFirst(6))) }
let developed = paths.first { $0.hasPrefix("--developed=") }.flatMap { DevelopedFormat(rawValue: String($0.dropFirst(12))) }
let removing = paths.contains("--private")
let quality = paths.first { $0.hasPrefix("--quality=") }.flatMap { Double($0.dropFirst(10)) }
let limit = paths.first { $0.hasPrefix("--limit=") }.flatMap { Int($0.dropFirst(8)) }
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

if let limit { sources = Array(sources.prefix(limit)) }
let work = FileManager.default.temporaryDirectory.appendingPathComponent("extract-bench-\(UUID().uuidString)")
let out = keep ?? work.appendingPathComponent("out"), copy = work.appendingPathComponent("copy")
try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: work) }

/// What V-22 must have removed and is still in `url`: read with ImageIO, and with the reference reader if PREVIEW_ORACLE is set.
func privateLeft(in url: URL) -> [String] {
    var left: [String] = []
    let p = CGImageSourceCreateWithURL(url as CFURL, nil).flatMap { CGImageSourceCopyPropertiesAtIndex($0, 0, nil) as? [CFString: Any] } ?? [:]
    if p[kCGImagePropertyGPSDictionary] != nil { left.append("ImageIO: GPS dictionary") }
    let exif = p[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
    for key in [kCGImagePropertyExifBodySerialNumber, kCGImagePropertyExifLensSerialNumber, kCGImagePropertyExifCameraOwnerName,
                kCGImagePropertyExifImageUniqueID] where exif[key] != nil { left.append("ImageIO: Exif \(key)") }
    if let iptc = p[kCGImagePropertyIPTCDictionary] as? [CFString: Any] {
        for key in [kCGImagePropertyIPTCCity, kCGImagePropertyIPTCSubLocation, kCGImagePropertyIPTCCreatorContactInfo] where iptc[key] != nil {
            left.append("ImageIO: IPTC \(key)")
        }
    }
    if let oracle = ProcessInfo.processInfo.environment["PREVIEW_ORACLE"] {
        let task = Process(), pipe = Pipe()
        task.executableURL = URL(fileURLWithPath: oracle)
        task.arguments = ["-a", "-G1", "-s", url.path]
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        if (try? task.run()) != nil {
            let text = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            task.waitUntilExit()
            let words = ["gps", "serial", "owner", "uniqueid", "makernote", "drone", "contactinfo", "sublocation", "locationshown", "locationcreated"]
            for line in text.split(separator: "\n") {
                let lower = line.lowercased()
                if words.contains(where: lower.contains) { left.append("reference reader: \(line.prefix(100))") }
            }
        }
    }
    return left
}

/// How many `sources` carry GPS, a serial number or a maker note at all.
func sourcesWithPrivate(_ sources: [URL]) -> (gps: Int, serial: Int) {
    var gps = 0, serial = 0
    for url in sources {
        let p = CGImageSourceCreateWithURL(url as CFURL, nil).flatMap { CGImageSourceCopyPropertiesAtIndex($0, 0, nil) as? [CFString: Any] } ?? [:]
        if p[kCGImagePropertyGPSDictionary] != nil { gps += 1 }
        let exif = p[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        if exif[kCGImagePropertyExifBodySerialNumber] != nil || exif[kCGImagePropertyExifLensSerialNumber] != nil { serial += 1 }
    }
    return (gps, serial)
}

let clock = ContinuousClock()
func seconds(_ d: Duration) -> Double { Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18 }

if let developed {
    var summary = ExportSummary()
    let time = clock.measure { summary = DevelopedExporter.run(sources, into: out, as: developed, quality: quality, removePrivate: removing) }
    print("files \(sources.count), written \(summary.written), could not develop \(summary.couldNotDevelop.count), not RAW \(summary.notRaw.count), failed \(summary.failed.count), maker note skipped \(summary.makerNoteSkipped.count), XMP skipped \(summary.xmpSkipped.count), renamed \(summary.renamed.count)")
    print(String(format: "developed %.2f s, %.2f s per file", seconds(time), seconds(time) / Double(max(1, summary.written))))
    if !summary.makerNoteSkipped.isEmpty { print("MAKER NOTE NOT COPIED: \(summary.makerNoteSkipped.joined(separator: ", "))") }
    if !summary.xmpSkipped.isEmpty { print("XMP NOT COPIED: \(summary.xmpSkipped.joined(separator: ", "))") }
    for f in summary.couldNotDevelop + summary.failed { print("NOT WRITTEN \(f.name): \(f.detail)") }
    for f in summary.attributeWarnings { print("ATTRIBUTES \(f.name): \(f.detail)") }
    var bad = 0
    func props(_ url: URL) -> [CFString: Any] {
        CGImageSourceCreateWithURL(url as CFURL, nil).flatMap { CGImageSourceCopyPropertiesAtIndex($0, 0, nil) as? [CFString: Any] } ?? [:]
    }
    /// Numbers are compared to 1e-5 (GPS is stored as degrees, minutes and seconds, so a rewrite rounds below a metre).
    func text(_ v: Any?) -> String {
        guard let v else { return "-" }
        if let n = v as? Double ?? (v as? NSNumber)?.doubleValue, !(v is String) { return String(format: "%.5g", n) }
        return "\(v)"
    }
    /// GPS degrees are compared to 5e-6 (half a metre): ImageIO rewrites them as degrees, minutes and seconds.
    func gpsText(_ v: Any?, against other: Any?) -> String {
        if let a = v as? Double, let b = other as? Double, abs(a - b) < 5e-6 { return "same" }
        return (v as? Double).map { String(format: "%.7f", $0) } ?? text(v)
    }
    for source in sources {
        let stem = source.deletingPathExtension().lastPathComponent
        let output = out.appendingPathComponent("\(stem).\(developed.fileExtension)")
        guard FileManager.default.fileExists(atPath: output.path) else { continue }
        var problems: [String] = []
        let a = props(source), b = props(output)
        let ea = a[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:], eb = b[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        for key in [kCGImagePropertyExifDateTimeOriginal, kCGImagePropertyExifFNumber, kCGImagePropertyExifExposureTime,
                    kCGImagePropertyExifISOSpeedRatings, kCGImagePropertyExifFocalLength, kCGImagePropertyExifLensModel,
                    kCGImagePropertyExifBodySerialNumber] where (!removing || key != kCGImagePropertyExifBodySerialNumber) && ea[key] != nil && text(ea[key]) != text(eb[key]) {
            problems.append("Exif \(key): \(text(ea[key])) -> \(text(eb[key]))")
        }
        let ta = a[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:], tb = b[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        for key in [kCGImagePropertyTIFFMake, kCGImagePropertyTIFFModel] where text(ta[key]) != text(tb[key]) {
            problems.append("TIFF \(key): \(text(ta[key])) -> \(text(tb[key]))")
        }
        let ga = a[kCGImagePropertyGPSDictionary] as? [CFString: Any] ?? [:], gb = b[kCGImagePropertyGPSDictionary] as? [CFString: Any] ?? [:]
        for key in [kCGImagePropertyGPSLatitude, kCGImagePropertyGPSLongitude, kCGImagePropertyGPSLatitudeRef, kCGImagePropertyGPSLongitudeRef]
        where !removing && ga[key] != nil && gpsText(ga[key], against: gb[key]) != gpsText(gb[key], against: ga[key]) {
            problems.append("GPS \(key): \(gpsText(ga[key], against: gb[key])) -> \(gpsText(gb[key], against: ga[key]))")
        }
        if text(b[kCGImagePropertyOrientation]) != "1" { problems.append("orientation \(text(b[kCGImagePropertyOrientation]))") }
        if text(eb[kCGImagePropertyExifPixelXDimension]) != text(b[kCGImagePropertyPixelWidth]) { problems.append("Exif width \(text(eb[kCGImagePropertyExifPixelXDimension])) vs \(text(b[kCGImagePropertyPixelWidth]))") }
        let wantDepth = developed == .jpeg ? "8" : "10"
        if text(b[kCGImagePropertyDepth]) != wantDepth { problems.append("depth \(text(b[kCGImagePropertyDepth]))") }
        let wantProfile = developed == .jpeg ? "sRGB" : "Display P3"
        if !text(b[kCGImagePropertyProfileName]).hasPrefix(wantProfile) { problems.append("profile \(text(b[kCGImagePropertyProfileName]))") }
        let sa = try? FileManager.default.attributesOfItem(atPath: source.path), sb = try? FileManager.default.attributesOfItem(atPath: output.path)
        for key in [FileAttributeKey.creationDate, .modificationDate, .posixPermissions] where "\(sa?[key] ?? "")" != "\(sb?[key] ?? "")" {
            problems.append("file \(key.rawValue) differs")
        }
        let xa = (try? FileManager.default.listxattr(source)) ?? [], xb = (try? FileManager.default.listxattr(output)) ?? []
        if Set(xa).subtracting(xb).isEmpty == false { problems.append("xattrs missing: \(Set(xa).subtracting(xb).sorted())") }
        let size = "\(text(b[kCGImagePropertyPixelWidth]))x\(text(b[kCGImagePropertyPixelHeight]))"
        if removing { problems += privateLeft(in: output) }
        print(problems.isEmpty ? "ok   \(output.lastPathComponent) \(size)" : "FAIL \(output.lastPathComponent) \(size)")
        for p in problems { print("       \(p)"); }
        if !problems.isEmpty { bad += 1 }
    }
    exit(bad > 0 || summary.written == 0 ? 1 : 0)
}

if removing {
    let summary = EmbeddedJPEGExtractor.run(sources, into: out, exactBytes: exact, removePrivate: true)
    let had = sourcesWithPrivate(sources)
    print("files \(sources.count), written \(summary.written), no JPEG \(summary.withoutEmbeddedJPEG.count), failed \(summary.failed.count), XMP skipped \(summary.xmpSkipped.count); sources with GPS \(had.gps), with a serial number \(had.serial)")
    var bad = 0
    for source in sources {
        let output = out.appendingPathComponent(source.deletingPathExtension().lastPathComponent + ".jpg")
        guard FileManager.default.fileExists(atPath: output.path) else { continue }
        let left = privateLeft(in: output)
        print(left.isEmpty ? "ok   \(output.lastPathComponent)" : "FAIL \(output.lastPathComponent)")
        for l in left { print("       \(l)") }
        if !left.isEmpty { bad += 1 }
    }
    exit(bad > 0 || summary.written == 0 ? 1 : 0)
}

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

extension FileManager {
    /// Names of the extended attributes of `url`.
    func listxattr(_ url: URL) throws -> [String] {
        let size = Darwin.listxattr(url.path, nil, 0, 0)
        guard size > 0 else { return [] }
        var buffer = [CChar](repeating: 0, count: size)
        guard Darwin.listxattr(url.path, &buffer, size, 0) >= 0 else { return [] }
        return buffer.split(separator: 0).map { String(decoding: $0.map { UInt8(bitPattern: $0) }, as: UTF8.self) }
    }
}
