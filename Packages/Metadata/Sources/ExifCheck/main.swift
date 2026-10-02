// M-16 tool: prints what the EXIF reader finds in each file, and with PREVIEW_ORACLE=<path to a reference extractor>
// compares the values against it (numbers from the oracle are run through the same formatters).
//   ExifCheck <file>...
import Foundation
import Metadata

let files = CommandLine.arguments.dropFirst().map { URL(fileURLWithPath: $0) }
guard !files.isEmpty else {
    FileHandle.standardError.write(Data("usage: ExifCheck <file>...\n".utf8))
    exit(2)
}

func oracle(_ url: URL) -> [String: Any]? {
    guard let tool = ProcessInfo.processInfo.environment["PREVIEW_ORACLE"] else { return nil }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: tool)
    process.arguments = ["-j", "-n", "-Make", "-Model", "-LensModel", "-FocalLength", "-FocalLengthIn35mmFormat", "-FNumber",
                         "-ExposureTime", "-ISO", "-ExposureCompensation", "-EXIF:MeteringMode", "-Flash", "-WhiteBalance", "-FocusLocation", "-FocusPixel", "-AFPointsInFocus", "-AFPointsSelected",
                         "-AFAreaXPositions", "-AFAreaYPositions", "-AFImageWidth", "-AFImageHeight", "-AFAreaWidths", "-AFAreaHeights",
                         "-AFAreaXPosition", "-AFAreaYPosition", url.path]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    guard (try? process.run()) != nil else { return nil }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return ((try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]])?.first
}

func num(_ v: Any?) -> Double? { (v as? NSNumber)?.doubleValue ?? (v as? String).flatMap(Double.init) }

var compared = 0, mismatches = 0
for url in files {
    guard let info = ExifReader.read(from: url) else {
        print("\(url.lastPathComponent): no EXIF")
        continue
    }
    print("\(url.lastPathComponent)")
    for field in info.fields { print("  \(field.label): \(field.value)") }
    for field in info.afFields { print("  \(field.label): \(field.value)") }
    guard let ref = oracle(url) else { continue }
    // V-01: the AF point, as a fraction of the frame the camera reported it in, against the reference's numbers.
    func list(_ key: String) -> [Double] {
        (ref[key] as? String)?.split(separator: " ").compactMap { Double($0) } ?? (ref[key] as? NSNumber).map { [$0.doubleValue] } ?? []
    }
    var expectedAF: (Double, Double)?
    let focusLocation = list("FocusLocation"), focusPixel = list("FocusPixel")
    if focusLocation.count == 4 {
        expectedAF = (focusLocation[2] / focusLocation[0], focusLocation[3] / focusLocation[1])
    } else if focusPixel.count == 2, let w = info.maker?.afFrameWidth, let h = info.maker?.afFrameHeight {
        expectedAF = (focusPixel[0] / Double(w), focusPixel[1] / Double(h))
    } else if let w = list("AFImageWidth").first, let h = list("AFImageHeight").first {
        // Canon: bit numbers of the points in focus (or selected), positions from the middle with y up.
        let xs = list("AFAreaXPositions"), ys = list("AFAreaYPositions")
        func bitNumbers(_ key: String) -> [Int] {
            list(key).enumerated().flatMap { word, value in (0..<16).filter { Int(value) >> $0 & 1 == 1 }.map { word * 16 + $0 } }
        }
        let picked = bitNumbers("AFPointsInFocus").isEmpty ? bitNumbers("AFPointsSelected") : bitNumbers("AFPointsInFocus")
        let points = picked.filter { $0 < xs.count && $0 < ys.count }.map { (0.5 + xs[$0] / w, 0.5 - ys[$0] / h) }
        if !points.isEmpty {
            expectedAF = (points.reduce(0) { $0 + $1.0 } / Double(points.count), points.reduce(0) { $0 + $1.1 } / Double(points.count))
        }
    }
    if let expectedAF {
        compared += 1
        let got = info.maker?.afPoints.isEmpty == false
            ? (info.maker!.afPoints.reduce(0) { $0 + $1.x } / Double(info.maker!.afPoints.count),
               info.maker!.afPoints.reduce(0) { $0 + $1.y } / Double(info.maker!.afPoints.count)) : nil
        if let got, abs(got.0 - expectedAF.0) < 0.001, abs(got.1 - expectedAF.1) < 0.001 {
            print("  AF point matches the reference")
        } else {
            mismatches += 1
            print("  MISMATCH AF point: reference \(expectedAF), ours \(got.map { "\($0)" } ?? "none")")
        }
    }
    let expected: [(String, String?, String?)] = [
        ("Camera", ExifFormat.camera(make: ref["Make"] as? String, model: ref["Model"] as? String), info.camera),
        // A lens EXIF does not name is composed from LensInfo, which the reference reports as its own tag.
        ("Lens", (ref["LensModel"] as? String) ?? info.lens, info.lens),
        ("Focal length", num(ref["FocalLength"]).flatMap { ExifFormat.focalLength($0, equivalent35mm: num(ref["FocalLengthIn35mmFormat"])) }, info.focalLength),
        ("Aperture", num(ref["FNumber"]).flatMap(ExifFormat.aperture), info.aperture),
        ("Shutter", num(ref["ExposureTime"]).flatMap(ExifFormat.shutter), info.shutter),
        ("ISO", num(ref["ISO"]).flatMap { ExifFormat.iso(Int($0)) }, info.iso),
        ("Exposure comp.", num(ref["ExposureCompensation"]).flatMap(ExifFormat.exposureCompensation), info.exposureCompensation),
        ("Metering", num(ref["MeteringMode"]).flatMap { ExifFormat.meteringMode(Int($0)) }, info.metering),
        ("Flash", num(ref["Flash"]).map { ExifFormat.flash(Int($0)) }, info.flash),
        ("White balance", num(ref["WhiteBalance"]).flatMap { ExifFormat.whiteBalance(Int($0)) }, info.whiteBalance),
    ]
    for (label, want, got) in expected {
        // A field the oracle has and we lack, or the other way round, or a different value.
        guard want != nil || got != nil else { continue }
        compared += 1
        if want != got {
            mismatches += 1
            print("  MISMATCH \(label): reference \(want ?? "none"), ours \(got ?? "none")")
        }
    }
}
if ProcessInfo.processInfo.environment["PREVIEW_ORACLE"] != nil { print("\(compared) values compared, \(mismatches) differ") }
