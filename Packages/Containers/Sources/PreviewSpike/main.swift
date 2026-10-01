// F-03 spike tool. Not shipped; the production reader is built in M-02.
//   PreviewSpike list   <files...>   what the locator finds
//   PreviewSpike verify <files...>   compare extracted bytes with a reference extractor (test oracle only)
//   PreviewSpike bench  <files...>   time locate, read and decode, and compare with ImageIO
import Containers
import CryptoKit
import Foundation
import ImageIO

let args = CommandLine.arguments.dropFirst()
if CommandLine.arguments.contains("verify"), ProcessInfo.processInfo.environment["PREVIEW_ORACLE"] == nil {
    FileHandle.standardError.write(Data("verify needs PREVIEW_ORACLE=<path to the reference extractor>\n".utf8))
    exit(2)
}
guard let command = args.first, ["list", "verify", "bench"].contains(command), args.count > 1 else {
    FileHandle.standardError.write(Data("usage: PreviewSpike list|verify|bench <files...>\n".utf8))
    exit(2)
}
let urls = args.dropFirst().map { URL(fileURLWithPath: $0) }

func describe(_ p: EmbeddedJPEG) -> String {
    let icc = p.header.hasICCProfile ? "icc" : "no-icc"
    let exif = p.header.hasExif ? "exif(orient=\(p.header.exifOrientation.map(String.init) ?? "none"))" : "no-exif"
    let tag = p.containerOrientation.map { "tag-orient=\($0)" } ?? "tag-orient=none"
    return "\(p.location) \(p.width)x\(p.height) @\(p.offset)+\(p.length) \(icc) \(exif) \(tag)"
}

func list(_ url: URL) throws {
    print("== \(url.lastPathComponent)")
    guard let found = try PreviewLocator.locate(at: url) else { print("  no previews found"); return }
    let i = found.info
    print("  \(found.format) \(i.make ?? "?") \(i.model ?? "?") orientation=\(i.orientation.map(String.init) ?? "none") interop=\(i.interopIndex ?? "none") colorspace=\(i.exifColorSpace.map(String.init) ?? "none")")
    for p in found.previews { print("  + " + describe(p)) }
    for s in found.skipped { print("  - \(s.location): \(s.reason)") }
}

/// The oracle is an external tool, never a dependency: its path comes from `PREVIEW_ORACLE`.
func oracleBytes(_ url: URL, group: String, tag: String) -> Data? {
    guard let tool = ProcessInfo.processInfo.environment["PREVIEW_ORACLE"] else { return nil }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: tool)
    p.arguments = ["-b", "-\(group):\(tag)", url.path]
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = FileHandle.nullDevice
    do { try p.run() } catch { return nil }
    let out = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return out.isEmpty ? nil : out
}

/// The oracle sometimes appends zero padding after the JPEG's EOI (CR3 `PRVW`); the bytes up to it must match.
func isSame(_ theirs: Data, _ mine: Data) -> Bool {
    theirs == mine || (theirs.starts(with: mine) && theirs.dropFirst(mine.count).allSatisfy { $0 == 0 })
}

func verify(_ url: URL) throws -> Bool {
    print("== \(url.lastPathComponent)")
    let data = try Data(contentsOf: url, options: .alwaysMapped)
    guard let found = PreviewLocator.locate(in: data) else { print("  no previews found"); return false }
    var ok = true
    for p in found.previews {
        let mine = PreviewLocator.bytes(of: p, in: data)
        var matched: String?
        // The oracle files some locations under another group name.
        let groups = [p.location] + (["RAF": ["File"], "THMB": ["Canon"], "PRVW": ["QuickTime"]][p.location] ?? [])
        search: for group in groups {
            for tag in ["PreviewImage", "JpgFromRaw", "ThumbnailImage", "OtherImage"] {
                if let theirs = oracleBytes(url, group: group, tag: tag), isSame(theirs, mine) { matched = "\(group):\(tag)"; break search }
            }
        }
        print("  \(matched != nil ? "OK  " : "FAIL") \(p.location) \(p.width)x\(p.height) \(p.length) bytes \(matched.map { "= \($0)" } ?? "no oracle tag gives identical bytes")")
        if matched == nil { ok = false }
    }
    return ok
}

// MARK: bench

let clock = ContinuousClock()
func ms(_ d: Duration) -> Double { Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15 }
func median(_ xs: [Double]) -> Double { xs.sorted()[xs.count / 2] }
func time<T>(_ body: () throws -> T) rethrows -> (T, Double) {
    var out: T?
    let d = try clock.measure { out = try body() }
    return (out!, ms(d))
}

/// Full decode of JPEG bytes via ImageIO.
func decode(_ jpeg: Data) -> CGImage? {
    let opts = [kCGImageSourceShouldCacheImmediately: true] as CFDictionary
    guard let src = CGImageSourceCreateWithData(jpeg as CFData, nil) else { return nil }
    return CGImageSourceCreateImageAtIndex(src, 0, opts)
}

func bench(_ url: URL) throws {
    let runs = 15
    print("== \(url.lastPathComponent)")
    guard let probe = try PreviewLocator.locate(at: url), let largest = probe.largest else { print("  no previews"); return }
    let grid = probe.smallestAdequate(longEdge: 320) ?? largest

    // Locate only: map the file, walk the headers.
    var locateT: [Double] = []
    for _ in 0..<runs {
        let (_, t) = try time { try PreviewLocator.locate(at: url) }
        locateT.append(t)
    }
    print("  locate (mmap + walk headers)   median \(String(format: "%.3f", median(locateT))) ms")

    for (label, p) in [("Grid ", grid), ("Loupe", largest)] {
        var readT: [Double] = [], decT: [Double] = [], totalT: [Double] = []
        for _ in 0..<runs {
            let (decoded, total) = try time { () -> CGImage? in
                let data = try Data(contentsOf: url, options: .alwaysMapped)
                let found = PreviewLocator.locate(in: data)!
                let q = found.previews.first { $0.offset == p.offset }!
                let bytes = Data(PreviewLocator.bytes(of: q, in: data))   // force the read
                return decode(bytes)
            }
            precondition(decoded != nil)
            totalT.append(total)
            let data = try Data(contentsOf: url, options: .alwaysMapped)
            let (bytes, r) = time { Data(PreviewLocator.bytes(of: p, in: data)) }
            let (_, d) = time { decode(bytes) }
            readT.append(r); decT.append(d)
        }
        print("  \(label) \(p.location) \(p.width)x\(p.height) \(p.length / 1024) KB: read \(String(format: "%.2f", median(readT))) ms, decode \(String(format: "%.2f", median(decT))) ms, locate+read+decode \(String(format: "%.2f", median(totalT))) ms")
    }

    // Decoding the extracted bytes at reduced size: ImageIO scales inside the JPEG decoder.
    for maxPx in [320, 1600, 2880] where maxPx < largest.longEdge {
        let data = try Data(contentsOf: url, options: .alwaysMapped)
        let bytes = Data(PreviewLocator.bytes(of: largest, in: data))
        var t: [Double] = []
        var size = ""
        for _ in 0..<runs {
            let (img, d) = time { () -> CGImage? in
                guard let src = CGImageSourceCreateWithData(bytes as CFData, nil) else { return nil }
                let o: [CFString: Any] = [kCGImageSourceThumbnailMaxPixelSize: maxPx,
                                          kCGImageSourceCreateThumbnailFromImageAlways: true,
                                          kCGImageSourceShouldCacheImmediately: true]
                return CGImageSourceCreateThumbnailAtIndex(src, 0, o as CFDictionary)
            }
            t.append(d)
            if let img { size = "\(img.width)x\(img.height)" }
        }
        print("  \(largest.location) bytes -> ImageIO thumb \(maxPx) -> \(size): median \(String(format: "%.2f", median(t))) ms")
    }
    // What ImageIO exposes for the RAW file.
    if let src = CGImageSourceCreateWithURL(url as CFURL, nil) {
        let sizes = (0..<CGImageSourceGetCount(src)).map { i -> String in
            let p = CGImageSourceCopyPropertiesAtIndex(src, i, nil) as? [CFString: Any]
            return "\(p?[kCGImagePropertyPixelWidth] ?? "?")x\(p?[kCGImagePropertyPixelHeight] ?? "?")"
        }
        print("  ImageIO images: \(sizes.joined(separator: ", "))")
    }
    // ImageIO's own path on the RAW file.
    for (label, maxPx, always) in [("thumb 320 ", 320, false), ("thumb 2048", 2048, false), ("thumb 8000", 8000, false)] {
        var t: [Double] = []
        var size = ""
        for _ in 0..<runs {
            let (img, ms) = time { () -> CGImage? in
                guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
                let o: [CFString: Any] = [kCGImageSourceThumbnailMaxPixelSize: maxPx,
                                          kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
                                          kCGImageSourceCreateThumbnailFromImageAlways: always,
                                          kCGImageSourceCreateThumbnailWithTransform: true,
                                          kCGImageSourceShouldCacheImmediately: true]
                return CGImageSourceCreateThumbnailAtIndex(src, 0, o as CFDictionary)
            }
            t.append(ms)
            if let img { size = "\(img.width)x\(img.height)" }
        }
        print("  ImageIO \(label) -> \(size.isEmpty ? "failed" : size): median \(String(format: "%.2f", median(t))) ms")
    }
}

var allOK = true
for url in urls {
    do {
        switch command {
        case "list": try list(url)
        case "verify": allOK = try verify(url) && allOK
        default: try bench(url)
        }
    } catch {
        print("  error: \(error)")
        allOK = false
    }
}
exit(allOK ? 0 : 1)
