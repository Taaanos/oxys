import Foundation

/// Turns EXIF numbers into the strings a photographer reads: 1/250 s, f/2.8, +⅓ EV, 35 mm.
public enum ExifFormat {
    /// Under a second as a fraction of the nearest whole denominator, from a second up as seconds.
    public static func shutter(_ seconds: Double) -> String? {
        guard seconds.isFinite, seconds > 0 else { return nil }
        if seconds >= 0.95 { return "\(trimmed(seconds, places: seconds < 10 ? 1 : 0)) s" }
        let denominator = (1 / seconds).rounded()
        return "1/\(Int(denominator)) s"
    }

    public static func aperture(_ fNumber: Double) -> String? {
        guard fNumber.isFinite, fNumber > 0 else { return nil }
        return "f/\(trimmed(fNumber, places: 1))"
    }

    /// Thirds of a stop get the vulgar fractions cameras show; anything else falls back to a decimal.
    public static func exposureCompensation(_ ev: Double) -> String? {
        guard ev.isFinite else { return nil }
        let thirds = (abs(ev) * 3).rounded()
        guard thirds != 0 else { return "0 EV" }
        let sign = ev < 0 ? "−" : "+"
        if abs(abs(ev) * 3 - thirds) < 0.1 {
            let whole = Int(thirds) / 3
            let fraction = ["", "⅓", "⅔"][Int(thirds) % 3]
            return "\(sign)\(whole == 0 ? "" : String(whole))\(fraction) EV"
        }
        return "\(sign)\(trimmed(abs(ev), places: 1)) EV"
    }

    public static func focalLength(_ mm: Double, equivalent35mm: Double? = nil) -> String? {
        guard mm.isFinite, mm > 0 else { return nil }
        var text = "\(trimmed(mm, places: 1)) mm"
        if let equivalent35mm, equivalent35mm > 0, abs(equivalent35mm - mm) >= 1 {
            text += " (\(trimmed(equivalent35mm, places: 0)) mm equiv.)"
        }
        return text
    }

    public static func iso(_ value: Int) -> String? { value > 0 ? "ISO \(value)" : nil }

    public static func meteringMode(_ code: Int) -> String? {
        switch code {
        case 1: "Average"
        case 2: "Center-weighted"
        case 3: "Spot"
        case 4: "Multi-spot"
        case 5: "Multi-segment"
        case 6: "Partial"
        default: nil
        }
    }

    public static func whiteBalance(_ code: Int) -> String? {
        switch code {
        case 0: "Auto"
        case 1: "Manual"
        default: nil
        }
    }

    /// Bit 0 of the EXIF flash field is "fired"; the rest describe modes that only matter when it did.
    public static func flash(_ code: Int) -> String {
        code & 1 == 1 ? "Fired" : "Did not fire"
    }

    /// "Canon" + "Canon EOS 7D" is "Canon EOS 7D"; "NIKON CORPORATION" + "NIKON D850" is "NIKON D850".
    public static func camera(make: String?, model: String?) -> String? {
        let make = make?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
        let model = model?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
        guard let model else { return make }
        guard let make else { return model }
        let brand = make.split(separator: " ").first.map(String.init) ?? make
        return model.lowercased().hasPrefix(brand.lowercased()) ? model : "\(make) \(model)"
    }

    /// `48.8584° N, 2.2945° E`, with 4 decimals (about 10 m).
    public static func coordinates(latitude: Double, longitude: Double) -> String {
        "\(trimmed(abs(latitude), places: 4))° \(latitude < 0 ? "S" : "N"), \(trimmed(abs(longitude), places: 4))° \(longitude < 0 ? "W" : "E")"
    }

    public static func fileSize(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    /// `places` decimals with trailing zeros dropped: 2.8, 8, 1.3.
    static func trimmed(_ value: Double, places: Int) -> String {
        var text = String(format: "%.\(places)f", value)
        if text.contains(".") {
            while text.hasSuffix("0") { text.removeLast() }
            if text.hasSuffix(".") { text.removeLast() }
        }
        return text
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
