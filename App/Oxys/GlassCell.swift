import AppKit
import Diagnostics
import Imaging
import Library

/// The glass lens on the active cell of a thumbnail view: Grid (D-13) and the film strip (V-20). The cell's
/// thumbnail is drawn through `GlassLens` with the decision marks under the glass, and the bitmap is kept until
/// the photo, its decision or the size changes. One cell is active at a time, so one bitmap is kept.
@MainActor
final class GlassCellLens {
    /// The shape of the glass in points. It stays the same in points on every cell size, like the bevel of a real
    /// pane of glass, so a big cell has a wider flat middle and not a wider rim.
    struct Look: Equatable {
        /// Width of the bending rim.
        var rim: CGFloat
        /// How far the picture is pulled in at the very edge.
        var pull: CGFloat
        var corner: CGFloat

        /// The bevel of the film strip's 80 pt cell (rim 15% of the cell). Grid uses it on every cell size too: a wider
        /// rim on a big cell sinks the capsule at the bottom deeper into the bend and melts the stars (seen at 240 pt
        /// with a 15 pt rim), while this rim bends the capsule as much as the strip does, which was accepted.
        static let bevel = Look(rim: 12, pull: 7.2, corner: 12.8)
    }

    private struct Key: Equatable {
        let image: GridThumbnailLoader.Key?
        let decision: Decision
        let isPair: Bool
        let isSelected: Bool
        let edge: Int
        let look: Look
    }
    private var kept: (key: Key, image: CGImage)?

    /// The lens for a cell of `points` × `points` on a display of `scale`: about 0.2 to 2 ms, and nothing at all
    /// while the key is the same. `plain` is the thumbnail (nil while it loads: the glass is then drawn over the
    /// tile), `imageKey` says which one it is. Falls back to `plain` if the bitmap cannot be made.
    func image(plain: CGImage?, imageKey: GridThumbnailLoader.Key?, decision: Decision, isPair: Bool, isSelected: Bool = false,
               points: CGFloat, scale: CGFloat, tile: Double, look: Look, signpost: PerfInterval? = nil) -> CGImage? {
        let edge = Int((points * scale).rounded())
        let key = Key(image: plain == nil ? nil : imageKey, decision: decision, isPair: isPair, isSelected: isSelected,
                  edge: edge, look: look)
        if let kept, kept.key == key { return kept.image }
        let token = signpost.map { Perf.begin($0) }
        defer { token.map { Perf.end($0) } }
        var style = GlassLens.Style()
        style.rimWidth = Double(look.rim / points)
        style.strength = Double(look.pull / points)
        style.cornerRadius = Double(look.corner / points)
        let made = GlassLens.apply(to: plain, edge: edge, background: tile, style: style) { ctx in
            Self.drawDecision(decision, isPair: isPair, isSelected: isSelected, points: points, tile: tile, into: ctx, edge: edge)
        }
        kept = made.map { (key, $0) }
        return made ?? plain
    }

    /// The veil that dims a reject, the tint of a selected cell and the marks, drawn into the lens bitmap in cell
    /// points (top-left origin, like the cell's own badge view). The tint is under the glass, so the rim keeps its
    /// light, and under the marks, so a red chip stays red.
    private static func drawDecision(_ decision: Decision, isPair: Bool, isSelected: Bool, points: CGFloat, tile: Double, into ctx: CGContext, edge: Int) {
        ctx.saveGState()
        defer { ctx.restoreGState() }
        ctx.translateBy(x: 0, y: CGFloat(edge))
        ctx.scaleBy(x: CGFloat(edge) / points, y: -CGFloat(edge) / points)
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        if decision.isReject {
            NSColor(white: tile, alpha: 0.65).setFill()
            NSRect(x: 0, y: 0, width: points, height: points).fill()
        }
        if isSelected {
            NSColor.controlAccentColor.withAlphaComponent(GridCellView.selectionTint).setFill()
            NSRect(x: 0, y: 0, width: points, height: points).fill()
        }
        GridBadgeView.drawBadges(decision: decision, isPair: isPair, in: GridBadgeView.strip(cellWidth: points, height: points))
    }
}
