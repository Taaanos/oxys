/// One value of the short EXIF line under a Compare pane, and whether the other pane's photo has another one (V-09).
public struct CompareField: Sendable, Equatable, Identifiable {
    public let label: String
    public let value: String
    public let differs: Bool
    public var id: String { label }

    public init(label: String, value: String, differs: Bool) {
        self.label = label
        self.value = value
        self.differs = differs
    }
}

extension ExifInfo {
    private struct Entry: Sendable {
        let label: String
        let value: @Sendable (ExifInfo) -> String?
        /// Core values are always in the line; the others only when they differ.
        let core: Bool
    }

    /// Focal length, aperture, shutter and ISO are what a photographer compares first. The rest of the exposure
    /// and camera settings appear only when they differ. Capture time, size and place are never "settings".
    private static let entries: [Entry] = [
        Entry(label: "Focal length", value: { $0.focalLength }, core: true),
        Entry(label: "Aperture", value: { $0.aperture }, core: true),
        Entry(label: "Shutter", value: { $0.shutter }, core: true),
        Entry(label: "ISO", value: { $0.iso }, core: true),
        Entry(label: "Exposure comp.", value: { $0.exposureCompensation }, core: false),
        Entry(label: "White balance", value: { $0.whiteBalance }, core: false),
        Entry(label: "Metering", value: { $0.metering }, core: false),
        Entry(label: "Flash", value: { $0.flash }, core: false),
        Entry(label: "Lens", value: { $0.lens }, core: false),
        Entry(label: "Camera", value: { $0.camera }, core: false),
    ]

    /// This photo's values for the Compare line, marked where `other` has a different one. A value that one photo
    /// has and the other lacks counts as a difference. With no `other` (still loading) nothing is marked.
    public func compareFields(against other: ExifInfo?) -> [CompareField] {
        Self.entries.compactMap { entry in
            let mine = entry.value(self)
            let differs = other.map { entry.value($0) != mine } ?? false
            guard entry.core ? (mine != nil || differs) : differs else { return nil }
            return CompareField(label: entry.label, value: mine ?? "none", differs: differs)
        }
    }
}
