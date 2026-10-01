import Foundation
import ImageIO

/// Reads when a photo was taken without decoding any pixels (M-01). `ExifReader` (M-16) reads the same properties.
public enum CaptureTime {
    /// `DateTimeOriginal` plus sub-seconds and the UTC offset when the camera recorded one.
    /// Without an offset the wall-clock time is read in the Mac's current time zone, which is what a photographer expects
    /// for a shoot taken where they live. Returns nil when the file has no usable date.
    public static func read(from url: URL) -> Date? {
        guard let properties = ExifReader.properties(of: url),
              let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any],
              let original = exif[kCGImagePropertyExifDateTimeOriginal] as? String
        else { return nil }
        return parse(dateTimeOriginal: original,
                     subseconds: exif[kCGImagePropertyExifSubsecTimeOriginal] as? String,
                     offset: exif["OffsetTimeOriginal" as CFString] as? String)
    }

    /// `original` is EXIF's `yyyy:MM:dd HH:mm:ss`; `subseconds` the digits after the decimal point; `offset` is `±HH:MM`.
    public static func parse(dateTimeOriginal original: String, subseconds: String? = nil, offset: String? = nil,
                             timeZone: TimeZone = .current) -> Date? {
        let parts = original.trimmingCharacters(in: .whitespaces).split(whereSeparator: { $0 == ":" || $0 == " " })
        guard parts.count == 6, let numbers = Optional(parts.compactMap { Int($0) }), numbers.count == 6 else { return nil }

        var zone = timeZone
        if let offset, let seconds = secondsFromGMT(offset), let tz = TimeZone(secondsFromGMT: seconds) { zone = tz }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        var components = DateComponents()
        components.year = numbers[0]; components.month = numbers[1]; components.day = numbers[2]
        components.hour = numbers[3]; components.minute = numbers[4]; components.second = numbers[5]
        // Cameras write all zeros or blanks for "unset"; Calendar would turn month 0 into a real date.
        guard (1...12).contains(numbers[1]), (1...31).contains(numbers[2]),
              let date = calendar.date(from: components) else { return nil }

        guard let subseconds, let fraction = Double("0." + subseconds.trimmingCharacters(in: .whitespaces)) else { return date }
        return date.addingTimeInterval(fraction)
    }

    static func secondsFromGMT(_ offset: String) -> Int? {
        let text = offset.trimmingCharacters(in: .whitespaces)
        guard let sign = text.first, sign == "+" || sign == "-" else { return nil }
        let fields = text.dropFirst().split(separator: ":")
        guard fields.count == 2, let hours = Int(fields[0]), let minutes = Int(fields[1]),
              hours <= 14, minutes < 60 else { return nil }
        let total = hours * 3600 + minutes * 60
        return sign == "-" ? -total : total
    }
}
