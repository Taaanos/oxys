// F-06 spike tool. Not shipped; the production RAW path is built in V-02.
//   RawSpike flags <files...>            CIRAWFilter support flags, geometry, supportedCameraModels membership
//   RawSpike sharp <files...>            Laplacian variance of a 1:1 centre crop: CIRAWFilter default vs neutral
//   RawSpike time  <files...>            decode to a Metal texture, default and neutral (median of 7 after a cold run)
//   RawSpike dump  <file> <out.png>      write the neutral 1:1 centre crop (1024x1024) as PNG
//   RawSpike compare <raw> <ref.tiff> <outdir>   neutral CIRAWFilter vs a reference decode (16-bit TIFF, no sharpening): crops, stats, side-by-side PNG
import CoreImage
import Foundation
import ImageIO
import Imaging
import Metal
import UniformTypeIdentifiers

let args = Array(CommandLine.arguments.dropFirst())
guard let command = args.first, ["flags", "sharp", "time", "dump", "compare"].contains(command), args.count > 1 else {
    FileHandle.standardError.write(Data("usage: RawSpike flags|sharp|time <files...> | dump <file> <out.png>\n".utf8))
    exit(2)
}
let urls = command == "compare" ? [URL(fileURLWithPath: args[1])] : args.dropFirst().map { URL(fileURLWithPath: $0) }

guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { fatalError("no Metal") }
let context = CIContext(mtlCommandQueue: queue, options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)!])

/// Every detail-processing control at 0 where the camera supports it; reports what could not be switched off.
/// An unsupported control whose default is already 0 does nothing, so it counts as neutral.
func neutralize(_ f: CIRAWFilter) -> [String] {
    var stuck: [String] = []
    if f.isSharpnessSupported { f.sharpnessAmount = 0 } else if f.sharpnessAmount != 0 { stuck.append("sharpness") }
    if f.isLuminanceNoiseReductionSupported { f.luminanceNoiseReductionAmount = 0 } else if f.luminanceNoiseReductionAmount != 0 { stuck.append("lumaNR") }
    if f.isColorNoiseReductionSupported { f.colorNoiseReductionAmount = 0 } else if f.colorNoiseReductionAmount != 0 { stuck.append("colorNR") }
    if f.isDetailSupported { f.detailAmount = 0 } else if f.detailAmount != 0 { stuck.append("detail") }
    if f.isLocalToneMapSupported { f.localToneMapAmount = 0 } else if f.localToneMapAmount != 0 { stuck.append("localToneMap") }
    if f.isMoireReductionSupported { f.moireReductionAmount = 0 } else if f.moireReductionAmount != 0 { stuck.append("moire") }
    return stuck
}

func filter(_ url: URL, neutral: Bool) -> CIRAWFilter? {
    guard let f = CIRAWFilter(imageURL: url) else { return nil }
    if neutral { _ = neutralize(f) }
    return f
}

func yesNo(_ b: Bool) -> String { b ? "yes" : "no" }

func lumaCrop(_ image: CIImage, size: Int) -> (luma: [Float], w: Int, h: Int)? {
    let e = image.extent
    let w = min(size, Int(e.width)), h = min(size, Int(e.height))
    let cw = CGFloat(w), ch = CGFloat(h)
    let ox: CGFloat = e.minX + (e.width - cw) / 2
    let oy: CGFloat = e.minY + (e.height - ch) / 2
    let rect = CGRect(x: ox, y: oy, width: cw, height: ch).integral
    var px = [Float](repeating: 0, count: w * h * 4)
    px.withUnsafeMutableBytes {
        context.render(image, toBitmap: $0.baseAddress!, rowBytes: w * 16, bounds: rect, format: .RGBAf,
                       colorSpace: CGColorSpace(name: CGColorSpace.linearSRGB))
    }
    var luma = [Float](repeating: 0, count: w * h)
    for i in 0..<(w * h) { luma[i] = 0.2126 * px[i * 4] + 0.7152 * px[i * 4 + 1] + 0.0722 * px[i * 4 + 2] }
    return (luma, w, h)
}

func texture(for image: CIImage) -> Double {
    let e = image.extent
    let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: Int(e.width), height: Int(e.height), mipmapped: false)
    d.usage = [.shaderRead, .shaderWrite, .renderTarget]
    d.storageMode = .private
    let tex = device.makeTexture(descriptor: d)!
    let dest = CIRenderDestination(mtlTexture: tex, commandBuffer: nil)
    dest.colorSpace = CGColorSpace(name: CGColorSpace.displayP3)
    let t0 = DispatchTime.now().uptimeNanoseconds
    do { try context.startTask(toRender: image, from: e, to: dest, at: e.origin).waitUntilCompleted() } catch { print("  render failed: \(error)") }
    return Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6
}

let supported = Set(CIRAWFilter.supportedCameraModels)
print("CIRAWFilter.supportedCameraModels: \(supported.count) models")

for url in urls {
    print("== \(url.lastPathComponent)")
    guard let f = CIRAWFilter(imageURL: url) else { print("  CIRAWFilter refused the file"); continue }
    switch command {
    case "flags":
        let stuck = neutralize(CIRAWFilter(imageURL: url)!)
        let props = CGImageSourceCopyPropertiesAtIndex(CGImageSourceCreateWithURL(url as CFURL, nil)!, 0, nil) as? [CFString: Any]
        let tiff = props?[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        let model = (tiff?[kCGImagePropertyTIFFModel] as? String) ?? "?"
        let make = (tiff?[kCGImagePropertyTIFFMake] as? String) ?? "?"
        let listed = supported.contains { $0.localizedCaseInsensitiveContains(model) || model.localizedCaseInsensitiveContains($0) }
        print("  camera: \(make) \(model); in supportedCameraModels: \(yesNo(listed)) (substring match); decoder \(f.decoderVersion)")
        print("  nativeSize \(Int(f.nativeSize.width))x\(Int(f.nativeSize.height)) orientation \(f.orientation.rawValue); output extent \(f.outputImage.map { "\(Int($0.extent.width))x\(Int($0.extent.height))" } ?? "none")")
        print("  supported: sharpness \(yesNo(f.isSharpnessSupported)), lumaNR \(yesNo(f.isLuminanceNoiseReductionSupported)), colorNR \(yesNo(f.isColorNoiseReductionSupported)), detail \(yesNo(f.isDetailSupported)), localToneMap \(yesNo(f.isLocalToneMapSupported)), moire \(yesNo(f.isMoireReductionSupported)), lensCorrection \(yesNo(f.isLensCorrectionSupported)), contrast \(yesNo(f.isContrastSupported))")
        print("  defaults: sharpness \(f.sharpnessAmount) lumaNR \(f.luminanceNoiseReductionAmount) colorNR \(f.colorNoiseReductionAmount) detail \(f.detailAmount) localToneMap \(f.localToneMapAmount) moire \(f.moireReductionAmount) lensCorrection \(f.isLensCorrectionEnabled) gamutMapping \(f.isGamutMappingEnabled)")
        print("  neutral: \(stuck.isEmpty ? "all controls switchable to 0" : "cannot switch off: " + stuck.joined(separator: ", "))")
    case "sharp":
        guard let d = filter(url, neutral: false)?.outputImage, let n = filter(url, neutral: true)?.outputImage,
              let dc = lumaCrop(d, size: 1024), let nc = lumaCrop(n, size: 1024) else { print("  no output"); continue }
        let dv = SharpnessMetric.laplacianVariance(luma: dc.luma, width: dc.w, height: dc.h)
        let nv = SharpnessMetric.laplacianVariance(luma: nc.luma, width: nc.w, height: nc.h)
        print(String(format: "  1:1 centre crop %dx%d  laplacian variance: default %.6f  neutral %.6f  ratio default/neutral %.2f", dc.w, dc.h, dv, nv, nv > 0 ? dv / nv : .nan))
    case "time":
        var rows: [String] = []
        for neutral in [false, true] {
            guard let image = filter(url, neutral: neutral)?.outputImage else { continue }
            let cold = texture(for: image)
            var runs: [Double] = []
            for _ in 0..<7 { guard let img = filter(url, neutral: neutral)?.outputImage else { break }; runs.append(texture(for: img)) }
            runs.sort()
            rows.append(String(format: "  %@: %.0fx%.0f  cold %.0f ms  median %.0f ms  (min %.0f, max %.0f)", neutral ? "neutral" : "default", image.extent.width, image.extent.height, cold, runs[runs.count / 2], runs.first ?? 0, runs.last ?? 0))
        }
        rows.forEach { print($0) }
    case "dump":
        guard args.count == 3, let image = filter(url, neutral: true)?.outputImage else { print("usage: dump <file> <out.png>"); exit(2) }
        let e = image.extent
        let rect = CGRect(x: e.midX - 512, y: e.midY - 512, width: 1024, height: 1024).integral
        guard let cg = context.createCGImage(image, from: rect, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)),
              let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: args[2]) as CFURL, UTType.png.identifier as CFString, 1, nil) else { print("  failed"); exit(1) }
        CGImageDestinationAddImage(dest, cg, nil); CGImageDestinationFinalize(dest)
    case "compare":
        guard args.count == 4, let ref = CIImage(contentsOf: URL(fileURLWithPath: args[2])), let ours = filter(url, neutral: true)?.outputImage else { print("usage: compare <raw> <ref.tiff> <outdir>"); exit(2) }
        let size = 1024
        guard let a = lumaCrop(ours, size: size), let b = lumaCrop(ref, size: size) else { print("  no output"); continue }
        print("  CIRAWFilter \(Int(ours.extent.width))x\(Int(ours.extent.height))  reference \(Int(ref.extent.width))x\(Int(ref.extent.height))  crop \(a.w)x\(a.h) vs \(b.w)x\(b.h)")
        guard a.w == b.w, a.h == b.h else { print("  crop sizes differ; skipping stats"); continue }
        // Tone curves differ between the two decoders, so the raw Laplacian variance is not comparable.
        // Dividing by the luma variance gives a contrast-normalised sharpness (edge energy per unit of contrast).
        func norm(_ c: (luma: [Float], w: Int, h: Int)) -> (lap: Double, lumaVar: Double, mean: Double) {
            let n = Double(c.luma.count)
            let mean = c.luma.reduce(0.0) { $0 + Double($1) } / n
            let v = c.luma.reduce(0.0) { $0 + (Double($1) - mean) * (Double($1) - mean) } / n
            return (SharpnessMetric.laplacianVariance(luma: c.luma, width: c.w, height: c.h), v, mean)
        }
        let na = norm(a), nb = norm(b)
        let ra = na.lap / max(na.lumaVar, 1e-12), rb = nb.lap / max(nb.lumaVar, 1e-12)
        print(String(format: "  mean luma: CIRAWFilter %.4f  reference %.4f", na.mean, nb.mean))
        print(String(format: "  contrast-normalised laplacian: CIRAWFilter %.6f  reference %.6f  ratio CI/ref %.2f", ra, rb, rb > 0 ? ra / rb : .nan))
        let outdir = URL(fileURLWithPath: args[3]); try? FileManager.default.createDirectory(at: outdir, withIntermediateDirectories: true)
        let base = url.deletingPathExtension().lastPathComponent
        // Side by side: left CIRAWFilter, right reference, both rendered through sRGB.
        let sideBySide = ours.cropped(to: CGRect(x: ours.extent.midX - 256, y: ours.extent.midY - 256, width: 512, height: 512).integral)
        let refCrop = ref.cropped(to: CGRect(x: ref.extent.midX - 256, y: ref.extent.midY - 256, width: 512, height: 512).integral)
        let left = sideBySide.transformed(by: CGAffineTransform(translationX: -sideBySide.extent.minX, y: -sideBySide.extent.minY))
        let right = refCrop.transformed(by: CGAffineTransform(translationX: 512 - refCrop.extent.minX, y: -refCrop.extent.minY))
        let both = right.composited(over: left)
        if let cg = context.createCGImage(both, from: CGRect(x: 0, y: 0, width: 1024, height: 512), format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)),
           let dest = CGImageDestinationCreateWithURL(outdir.appendingPathComponent("\(base)-cirawfilter-left-reference-right.png") as CFURL, UTType.png.identifier as CFString, 1, nil) {
            CGImageDestinationAddImage(dest, cg, nil); CGImageDestinationFinalize(dest)
        }
        var absDiff = 0.0
        for i in 0..<a.luma.count { absDiff += abs(Double(a.luma[i]) - Double(b.luma[i])) }
        print(String(format: "  mean |luma diff| %.4f", absDiff / Double(a.luma.count)))
    default: break
    }
}
