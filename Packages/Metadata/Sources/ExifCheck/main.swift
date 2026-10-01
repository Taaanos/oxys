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
                         "-ExposureTime", "-ISO", "-ExposureCompensation", "-EXIF:MeteringMode", "-Flash", "-WhiteBalance", url.path]
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
    guard let ref = oracle(url) else { continue }
    let expected: [(String, String?, String?)] = [
        ("Camera", ExifFormat.camera(make: ref["Make"] as? String, model: ref["Model"] as? String), info.camera),
        ("Lens", (ref["LensModel"] as? String), info.lens),
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
