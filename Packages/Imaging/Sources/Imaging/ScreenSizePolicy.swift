/// P-03: when a cold frame is decoded small first, and how small. A JPEG decoder can produce 1/2, 1/4 or 1/8 of the
/// size by cutting the work in the transform; any other size costs more than the full decode (measured with
/// `MaxPixelSize` on a 7,008 px ARW: 1/2 = 35 ms, 3,000 px = 59 ms, 3,840 px = 143 ms, full = 53 ms). So the
/// screen-size frame is the smallest of those exact fractions that still has about the pixels of the screen.
public enum ScreenSizePolicy {
    /// The fractions the JPEG decoder takes (ImageIO's subsample factor), the smallest picture first.
    static let factors = [8, 4, 2]
    /// The frame may have this share of the drawable's long edge: a little soft for the 100 ms before the full
    /// frame replaces it, never a blocky one.
    public static let minimumSharpness = 0.75

    /// The factor to decode the screen-size frame at (the picture has 1/factor of the preview's width and height),
    /// or nil when the preview should load in one step because no cheap fraction is big enough for the screen.
    /// - Parameters:
    ///   - sourceLongEdge: long edge in pixels of the preview as stored.
    ///   - drawableLongEdge: long edge in pixels of the view's drawable (not points).
    public static func subsampleFactor(sourceLongEdge: Int, drawableLongEdge: Int) -> Int? {
        guard drawableLongEdge > 0, sourceLongEdge > 0 else { return nil }
        return factors.first { Double((sourceLongEdge + $0 - 1) / $0) >= Double(drawableLongEdge) * minimumSharpness }
    }
}
