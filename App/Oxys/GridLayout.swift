import AppKit
import Library

/// Grid's layout (P-08). The photos sit on a regular grid, so every frame is arithmetic (`GridGeometry`) and a
/// pass costs time in proportion to the cells on screen. `NSCollectionViewFlowLayout` builds attributes for all
/// of the photos on each reload, and that took 27 ms for 10,000 of them: a dropped frame whenever the list was
/// replaced (a re-sort when the capture times arrive, a filter). It lays cells out the way the flow layout did:
/// each row spread over the width between the insets.
final class GridLayout: NSCollectionViewLayout {
    /// The cell edge in points. A change lays everything out again.
    var itemSize: CGFloat = GridGeometry.itemSizes[GridGeometry.defaultStep] {
        didSet { if itemSize != oldValue { invalidateLayout() } }
    }

    private var count: Int { collectionView?.numberOfItems(inSection: 0) ?? 0 }

    var geometry: GridGeometry { .grid(itemSize: itemSize, width: collectionView?.bounds.width ?? 0) }

    override var collectionViewContentSize: NSSize {
        NSSize(width: collectionView?.bounds.width ?? 0, height: geometry.contentHeight(count: count))
    }

    override func layoutAttributesForElements(in rect: NSRect) -> [NSCollectionViewLayoutAttributes] {
        let g = geometry
        return g.indices(in: rect, count: count).map { attributes(at: $0, geometry: g) }
    }

    override func layoutAttributesForItem(at indexPath: IndexPath) -> NSCollectionViewLayoutAttributes? {
        guard indexPath.item >= 0, indexPath.item < count else { return nil }
        return attributes(at: indexPath.item, geometry: geometry)
    }

    /// Scrolling moves the visible rect only; a new width changes the columns and the gaps.
    override func shouldInvalidateLayout(forBoundsChange newBounds: NSRect) -> Bool {
        newBounds.width != collectionView?.bounds.width
    }

    private func attributes(at index: Int, geometry: GridGeometry) -> NSCollectionViewLayoutAttributes {
        let attributes = NSCollectionViewLayoutAttributes(forItemWith: IndexPath(item: index, section: 0))
        attributes.frame = geometry.frame(of: index)
        return attributes
    }
}
