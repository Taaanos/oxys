/// EXIF orientation (tag 0x0112), guaranteed to be one of the 8 valid values (1...8).
public enum ExifOrientation: UInt16, Sendable, Equatable, Hashable, CaseIterable {
    case up = 1
    case upMirrored = 2
    case down = 3
    case downMirrored = 4
    case leftMirrored = 5
    case right = 6
    case rightMirrored = 7
    case left = 8

    /// True for orientations 5...8, which transpose width and height.
    public var swapsAxes: Bool { rawValue >= 5 }
}
