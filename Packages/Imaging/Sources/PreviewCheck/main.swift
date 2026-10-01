// M-02 tool: for each file, prints what the preview reader found and writes the upright Loupe and Grid
// renderings as PNGs, so orientation and color can be checked by eye against Preview.app.
//   PreviewCheck <out-dir> <files...>
import CoreImage
import Foundation
import ImageIO
import Imaging
import UniformTypeIdentifiers

let args = Array(CommandLine.arguments.dropFirst())
guard args.count >= 2 else {
    FileHandle.standardError.write(Data("usage: PreviewCheck <out-dir> <files...>\n".utf8))
    exit(2)
}
let outDir = URL(fileURLWithPath: args[0])
try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
let context = CIContext()
let rawExtensions: Set<String> = ["arw", "cr2", "cr3", "nef", "raf", "dng", "orf", "rw2", "pef"]

func writePNG(_ preview: DecodedPreview, to url: URL) {
    let upright = CIImage(cgImage: preview.image).oriented(preview.orientation)
    guard let cg = context.createCGImage(upright, from: upright.extent, format: .RGBA8, colorSpace: preview.image.colorSpace),
          let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
    else { return }
    CGImageDestinationAddImage(dest, cg, nil)
    CGImageDestinationFinalize(dest)
}

for path in args.dropFirst() {
    let url = URL(fileURLWithPath: path)
    let stem = url.deletingPathExtension().lastPathComponent.replacingOccurrences(of: " ", with: "_")
    do {
        let source = try PreviewSource.open(url, isRaw: rawExtensions.contains(url.pathExtension.lowercased()))
        let loupe = try source.decodeLoupe(maxPixelSize: 1600)
        let grid = try source.decodeGrid(longEdge: 320)
        let space = loupe.image.colorSpace?.name as String? ?? "unnamed"
        print("\(url.lastPathComponent): \(source.kind) \(loupe.sourceWidth)x\(loupe.sourceHeight) orientation=\(loupe.orientation.rawValue) display=\(loupe.sourceDisplaySize.width)x\(loupe.sourceDisplaySize.height) space=\(space) grid=\(grid.image.width)x\(grid.image.height)")
        writePNG(loupe, to: outDir.appendingPathComponent("\(stem)-loupe.png"))
        writePNG(grid, to: outDir.appendingPathComponent("\(stem)-grid.png"))
    } catch {
        print("\(url.lastPathComponent): ERROR \(error.localizedDescription)")
    }
}
