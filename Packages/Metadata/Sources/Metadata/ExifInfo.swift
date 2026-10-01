import Foundation

/// The facts about one frame that the info panel shows, already formatted. Every field is optional because
/// cameras leave out what they do not know; `fields` lists only the ones present.
public struct ExifInfo: Sendable, Equatable {
    public struct Field: Sendable, Equatable, Identifiable {
        public let label: String
        public let value: String
        public var id: String { label }
        public init(_ label: String, _ value: String) {
            self.label = label
            self.value = value
        }
    }

    public struct GPS: Sendable, Equatable {
        public let latitude: Double
        public let longitude: Double
        public let altitude: Double?

        /// Opens Apple Maps on the spot; coordinates only, no lookup happens in Oxys itself (M-16/Q1).
        public var mapsURL: URL? {
            URL(string: "https://maps.apple.com/?ll=\(latitude),\(longitude)&q=Photo")
        }
    }

    public var camera: String?
    public var lens: String?
    public var focalLength: String?
    public var aperture: String?
    public var shutter: String?
    public var iso: String?
    public var exposureCompensation: String?
    public var whiteBalance: String?
    public var metering: String?
    public var flash: String?
    public var captureTime: Date?
    /// Pixel size as the file's main image reports it (the sensor for a RAW), and the file's size on disk.
    public var dimensions: String?
    public var fileSize: String?
    public var gps: GPS?

    public init() {}

    public var fields: [Field] {
        var out: [Field] = []
        func add(_ label: String, _ value: String?) { if let value { out.append(Field(label, value)) } }
        add("Camera", camera)
        add("Lens", lens)
        add("Focal length", focalLength)
        add("Aperture", aperture)
        add("Shutter", shutter)
        add("ISO", iso?.replacingOccurrences(of: "ISO ", with: ""))
        add("Exposure comp.", exposureCompensation)
        add("White balance", whiteBalance)
        add("Metering", metering)
        add("Flash", flash)
        add("Taken", captureTime.map { $0.formatted(date: .abbreviated, time: .standard) })
        add("Dimensions", dimensions)
        add("File size", fileSize)
        add("GPS", gps.map { ExifFormat.coordinates(latitude: $0.latitude, longitude: $0.longitude) })
        return out
    }
}
