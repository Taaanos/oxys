import Foundation

/// The arithmetic behind the film strip in Loupe (V-20): where the strip scrolls so the active photo is in the
/// middle, which cells are on screen, and in what order their thumbnails are fetched. Pure, so it is tested
/// without a window. Every cell has the same width, so none of this needs a thumbnail.
public struct FilmStripGeometry: Sendable, Equatable {
    /// A cell is a square of this many points (V-20: 160 px at 2x).
    public static let cellSize: CGFloat = 80
    public static let spacing: CGFloat = 4
    /// Space above and below the cells.
    public static let verticalInset: CGFloat = 8
    /// The band the strip takes under the picture: the cells and the space around them.
    public static let bandHeight: CGFloat = cellSize + 2 * verticalInset

    public var width: CGFloat
    public var cellSize: CGFloat = FilmStripGeometry.cellSize
    public var spacing: CGFloat = FilmStripGeometry.spacing
    /// The least space before the first cell and after the last one.
    public var inset: CGFloat = 8

    public init(width: CGFloat) { self.width = width }

    public var pitch: CGFloat { cellSize + spacing }

    /// The width of all cells with the insets, when they do not fill the strip.
    public func contentWidth(count: Int) -> CGFloat {
        count == 0 ? 0 : 2 * inset + CGFloat(count) * pitch - spacing
    }

    /// Space before the first cell. A short list is centered in the strip, so there is no gap on one side only.
    public func leading(count: Int) -> CGFloat {
        max(inset, (width - (CGFloat(count) * pitch - spacing)) / 2)
    }

    /// Left edge of the cell at `index`, in the scroll view's document coordinates.
    public func origin(of index: Int, count: Int) -> CGFloat { leading(count: count) + CGFloat(index) * pitch }

    /// The document width: the cells, or the strip when they are fewer than it holds.
    public func documentWidth(count: Int) -> CGFloat {
        max(width, origin(of: count, count: count) - spacing + leading(count: count))
    }

    /// The scroll offset that puts the middle of the cell at `index` in the middle of the strip, stopped at the
    /// start and the end of the list, so a photo near an end shows no empty space past it.
    public func offset(centering index: Int, count: Int) -> CGFloat {
        guard count > 0 else { return 0 }
        let clamped = min(max(index, 0), count - 1)
        let middle = origin(of: clamped, count: count) + cellSize / 2
        return clamp(middle - width / 2, count: count)
    }

    /// An offset kept inside the document (a wheel scroll cannot go past either end).
    public func clamp(_ offset: CGFloat, count: Int) -> CGFloat {
        min(max(offset, 0), max(documentWidth(count: count) - width, 0))
    }

    /// The indices whose cells intersect the span `offset ..< offset + width`.
    public func visibleRange(offset: CGFloat, count: Int) -> Range<Int> {
        guard count > 0, width > 0 else { return 0..<0 }
        let lead = leading(count: count)
        let first = Int(((offset - lead) / pitch).rounded(.down))
        let last = Int(((offset + width - lead) / pitch).rounded(.down))
        let lower = min(max(first, 0), count)
        let upper = min(max(last + 1, 0), count)
        return lower..<max(upper, lower)
    }

    /// The photos to load, most wanted first: the visible cells and `margin` more on each side, nearest to
    /// `center` first, so a cell about to scroll in is ready.
    public func order(visible: Range<Int>, count: Int, center: Int, margin: Int = 4) -> [Int] {
        guard count > 0, !visible.isEmpty else { return [] }
        let lower = max(visible.lowerBound - margin, 0), upper = min(visible.upperBound + margin, count)
        return Array(lower..<upper).sorted {
            let a = abs($0 - center), b = abs($1 - center)
            return a != b ? a < b : $0 < $1
        }
    }
}
