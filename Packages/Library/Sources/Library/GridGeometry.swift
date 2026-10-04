import Foundation

/// The arithmetic behind Grid (M-12): how many columns fit, which photos are on screen, where an arrow key
/// goes, and in what order thumbnails should be fetched. Pure, so it is tested without a window.
public struct GridGeometry: Sendable, Equatable {
    /// The thumbnail sizes `−` and `=` step through (M-12/Q2): five steps, in points.
    public static let itemSizes: [CGFloat] = [120, 160, 240, 320, 480]
    public static let defaultStep = 2

    public static func clampedStep(_ step: Int) -> Int { min(max(step, 0), itemSizes.count - 1) }

    public var itemSize: CGFloat
    public var spacing: CGFloat = 6
    public var inset: CGFloat = 8
    /// The space at the right edge, which can differ from `inset`: Grid leaves room there for the scroller's knob.
    public var trailingInset: CGFloat
    public var width: CGFloat

    public init(itemSize: CGFloat, width: CGFloat, spacing: CGFloat = 6, inset: CGFloat = 8, trailingInset: CGFloat? = nil) {
        self.itemSize = itemSize
        self.width = width
        self.spacing = spacing
        self.inset = inset
        self.trailingInset = trailingInset ?? inset
    }

    /// The shape Grid draws: 8 pt at the top, bottom and left, 18 pt at the right, 6 pt between rows (P-08).
    public static func grid(itemSize: CGFloat, width: CGFloat) -> GridGeometry {
        GridGeometry(itemSize: itemSize, width: width, trailingInset: 18)
    }

    /// As many columns as fit between the insets, at least one: the same count a flow layout produces.
    public var columns: Int {
        let usable = width - inset - trailingInset + spacing
        return max(Int(usable / (itemSize + spacing)), 1)
    }

    /// The space between two cells of a row. A row is spread over the full width between the insets, as a flow layout
    /// does, so it is never less than `spacing`.
    public var columnGap: CGFloat {
        columns > 1 ? (width - inset - trailingInset - CGFloat(columns) * itemSize) / CGFloat(columns - 1) : spacing
    }

    /// The cell of `index` in the scroll view's document coordinates. Plain arithmetic, so a layout built on it costs
    /// time in proportion to the cells on screen and not to the folder (a flow layout took 27 ms for 10,000 photos).
    public func frame(of index: Int) -> CGRect {
        CGRect(x: inset + CGFloat(index % columns) * (itemSize + columnGap), y: rowOrigin(of: index),
               width: itemSize, height: itemSize)
    }

    /// The indices whose rows intersect `rect` (a vertical span, like `visibleRange`).
    public func indices(in rect: CGRect, count: Int) -> Range<Int> {
        visibleRange(offset: rect.minY, height: rect.height, count: count)
    }

    public func rows(count: Int) -> Int { count == 0 ? 0 : (count + columns - 1) / columns }

    public var rowPitch: CGFloat { itemSize + spacing }

    /// Top of the row that holds `index`, in the scroll view's document coordinates.
    public func rowOrigin(of index: Int) -> CGFloat { inset + CGFloat(index / columns) * rowPitch }

    public func contentHeight(count: Int) -> CGFloat {
        count == 0 ? 0 : 2 * inset + CGFloat(rows(count: count)) * rowPitch - spacing
    }

    /// The indices whose cells intersect the vertical span `offset ..< offset + height`.
    public func visibleRange(offset: CGFloat, height: CGFloat, count: Int) -> Range<Int> {
        guard count > 0, height > 0 else { return 0..<0 }
        let firstRow = max(Int(((offset - inset) / rowPitch).rounded(.down)), 0)
        let lastRow = max(Int(((offset + height - inset) / rowPitch).rounded(.down)), 0)
        let lower = min(firstRow * columns, count)
        let upper = min((lastRow + 1) * columns, count)
        return lower..<max(upper, lower)
    }

    /// Where an arrow key goes from `index`. Left and right step one photo (and wrap to the neighboring row,
    /// like reading); up and down step one row and stop at the first and last row. A move that cannot be
    /// made returns `index`. `count` must be positive.
    public func moved(from index: Int, _ move: Move, count: Int) -> Int {
        guard count > 0 else { return index }
        let clamped = min(max(index, 0), count - 1)
        switch move {
        case .left: return max(clamped - 1, 0)
        case .right: return min(clamped + 1, count - 1)
        case .up: return clamped - columns >= 0 ? clamped - columns : clamped
        case .down:
            // A short last row: land on its last photo, but only when the cursor was not already in that row.
            let below = clamped + columns
            if below < count { return below }
            let lastRow = (count - 1) / columns
            return clamped / columns < lastRow ? count - 1 : clamped
        }
    }

    public enum Move: Sendable { case left, right, up, down }
}

/// The order Grid fetches thumbnails in (M-12): what is on screen first, then the rows ahead in the scroll
/// direction, then a couple behind.
public enum GridPrefetch {
    public enum Direction: Sendable { case down, up }

    public static func order(visible: Range<Int>, count: Int, columns: Int, direction: Direction,
                             rowsAhead: Int = 4, rowsBehind: Int = 1) -> [Int] {
        guard count > 0, !visible.isEmpty else { return [] }
        let columns = max(columns, 1)
        let lower = max(visible.lowerBound, 0), upper = min(visible.upperBound, count)
        var result = Array(lower..<upper)
        let ahead = rowsAhead * columns, behind = rowsBehind * columns
        let after = Array(upper..<min(upper + (direction == .down ? ahead : behind), count))
        let before = Array(max(lower - (direction == .up ? ahead : behind), 0)..<lower)
        // Nearest first on both sides, the travel side leading.
        let beforeNearest = Array(before.reversed())
        result += direction == .down ? after + beforeNearest : beforeNearest + after
        return result
    }
}
