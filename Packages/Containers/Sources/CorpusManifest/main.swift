// F-02 tool: writes a JSON manifest of every camera file in a folder (default TestData/).
//   CorpusManifest <folder> > manifest.json
// Files are sniffed by content, not extension (the pixls corpus names many RAWs ".tiff").
import Containers
import Foundation
import ImageIO

struct PreviewEntry: Codable {
    var location: String
    var width: Int
    var height: Int
    var bytes: Int
}

struct Entry: Codable {
    var file: String
    var bytes: Int
    var format: String
    var make: String?
    var model: String?
    /// Largest image ImageIO reports for the file. Usually the sensor size, but ImageIO sometimes
    /// reports only a preview (CR3 shows its 4320x2880 preview) or nothing (PEF), so treat as approximate.
    var pixelWidth: Int?
    var pixelHeight: Int?
    var megapixels: Double?
    var previews: [PreviewEntry]
}

func entry(for url: URL) -> Entry? {
    guard let data = try? Data(contentsOf: url, options: .alwaysMapped),
          let found = PreviewLocator.locate(in: data) else { return nil }
    var pixels: (w: Int, h: Int)?
    if let src = CGImageSourceCreateWithURL(url as CFURL, nil) {
        for i in 0..<CGImageSourceGetCount(src) {
            guard let p = CGImageSourceCopyPropertiesAtIndex(src, i, nil) as? [CFString: Any],
                  let w = p[kCGImagePropertyPixelWidth] as? Int, let h = p[kCGImagePropertyPixelHeight] as? Int else { continue }
            if w * h > (pixels.map { $0.w * $0.h } ?? 0) { pixels = (w, h) }
        }
    }
    return Entry(file: url.lastPathComponent, bytes: data.count, format: found.format,
                 make: found.info.make, model: found.info.model,
                 pixelWidth: pixels?.w, pixelHeight: pixels?.h,
                 megapixels: pixels.map { (Double($0.w * $0.h) / 1e5).rounded() / 10 },
                 previews: found.previews.map { PreviewEntry(location: $0.location, width: $0.width, height: $0.height, bytes: $0.length) })
}

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: CorpusManifest <folder>\n".utf8))
    exit(2)
}
let folder = URL(fileURLWithPath: CommandLine.arguments[1])
let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path))?.sorted() ?? []
var entries: [Entry] = []
for name in names where !name.hasPrefix(".") && name != "manifest.json" {
    let url = folder.appendingPathComponent(name)
    var isDir: ObjCBool = false
    guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue else { continue }
    if let e = entry(for: url) { entries.append(e) } else {
        FileHandle.standardError.write(Data("skipped (not a recognised camera file): \(name)\n".utf8))
    }
}
let encoder = JSONEncoder()
encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
FileHandle.standardOutput.write(try encoder.encode(entries))
print()
