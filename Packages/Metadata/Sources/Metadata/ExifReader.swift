import Foundation
import ImageIO
import Synchronization

/// Reads EXIF through ImageIO without decoding pixels (M-16). The capture time comes from the same properties
/// dictionary the other fields do, so M-01's scan and the info panel agree.
public enum ExifReader {
    public static func read(from url: URL) -> ExifInfo? {
        guard let properties = properties(of: url) else { return nil }
        var info = parse(properties)
        if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize { info.fileSize = ExifFormat.fileSize(size) }
        return info
    }

    /// The first image's property dictionary; no pixels are decoded and nothing is cached by ImageIO.
    static func properties(of url: URL) -> [CFString: Any]? {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, options) else { return nil }
        return CGImageSourceCopyPropertiesAtIndex(source, 0, options) as? [CFString: Any]
    }

    /// Split from `read` so tests can feed a dictionary.
    public static func parse(_ properties: [CFString: Any]) -> ExifInfo {
        var info = ExifInfo()
        let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        let gps = properties[kCGImagePropertyGPSDictionary] as? [CFString: Any] ?? [:]

        info.camera = ExifFormat.camera(make: tiff[kCGImagePropertyTIFFMake] as? String,
                                        model: tiff[kCGImagePropertyTIFFModel] as? String)
        info.lens = (exif[kCGImagePropertyExifLensModel] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        if let mm = number(exif[kCGImagePropertyExifFocalLength]) {
            info.focalLength = ExifFormat.focalLength(mm, equivalent35mm: number(exif[kCGImagePropertyExifFocalLenIn35mmFilm]))
        }
        info.aperture = number(exif[kCGImagePropertyExifFNumber]).flatMap(ExifFormat.aperture)
        info.shutter = number(exif[kCGImagePropertyExifExposureTime]).flatMap(ExifFormat.shutter)
        if let isos = exif[kCGImagePropertyExifISOSpeedRatings] as? [Any], let first = isos.first.flatMap(number) {
            info.iso = ExifFormat.iso(Int(first))
        }
        info.exposureCompensation = number(exif[kCGImagePropertyExifExposureBiasValue]).flatMap(ExifFormat.exposureCompensation)
        info.whiteBalance = number(exif[kCGImagePropertyExifWhiteBalance]).flatMap { ExifFormat.whiteBalance(Int($0)) }
        info.metering = number(exif[kCGImagePropertyExifMeteringMode]).flatMap { ExifFormat.meteringMode(Int($0)) }
        info.flash = number(exif[kCGImagePropertyExifFlash]).map { ExifFormat.flash(Int($0)) }

        if let original = exif[kCGImagePropertyExifDateTimeOriginal] as? String {
            info.captureTime = CaptureTime.parse(dateTimeOriginal: original,
                                                 subseconds: exif[kCGImagePropertyExifSubsecTimeOriginal] as? String,
                                                 offset: exif["OffsetTimeOriginal" as CFString] as? String)
        }
        if let w = number(properties[kCGImagePropertyPixelWidth]), let h = number(properties[kCGImagePropertyPixelHeight]), w > 0, h > 0 {
            info.dimensions = "\(Int(w)) × \(Int(h))"
        }
        if let lat = number(gps[kCGImagePropertyGPSLatitude]), let lon = number(gps[kCGImagePropertyGPSLongitude]) {
            let south = (gps[kCGImagePropertyGPSLatitudeRef] as? String)?.uppercased() == "S"
            let west = (gps[kCGImagePropertyGPSLongitudeRef] as? String)?.uppercased() == "W"
            var altitude = number(gps[kCGImagePropertyGPSAltitude])
            if let a = altitude, number(gps[kCGImagePropertyGPSAltitudeRef]) == 1 { altitude = -a }
            info.gps = ExifInfo.GPS(latitude: south ? -abs(lat) : abs(lat), longitude: west ? -abs(lon) : abs(lon), altitude: altitude)
        }
        return info
    }

    private static func number(_ value: Any?) -> Double? {
        (value as? NSNumber)?.doubleValue
    }
}

/// Reads are lazy and cached per file (M-16). Bounded, so a 10,000-photo folder does not keep every entry;
/// when it is full the oldest half goes. A file that has no EXIF is remembered too.
public final class ExifCache: Sendable {
    private struct State {
        var entries: [URL: ExifInfo?] = [:]
        var order: [URL] = []
    }
    private let state = Mutex(State())
    private let capacity: Int

    public init(capacity: Int = 2000) { self.capacity = capacity }

    /// The cached value, if the file was read before. A nested nil means "read, nothing there".
    public func cached(_ url: URL) -> ExifInfo?? { state.withLock { $0.entries[url] } }

    /// Reads on the calling thread when not cached; call from a background task.
    public func info(for url: URL) -> ExifInfo? {
        if let hit = cached(url) { return hit }
        let info = ExifReader.read(from: url)
        state.withLock { state in
            if state.entries.updateValue(info, forKey: url) == nil { state.order.append(url) }
            if state.order.count > capacity {
                for old in state.order.prefix(capacity / 2) { state.entries[old] = nil }
                state.order.removeFirst(capacity / 2)
            }
        }
        return info
    }

    public func removeAll() { state.withLock { $0 = State() } }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
