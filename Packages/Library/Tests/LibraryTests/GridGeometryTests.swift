import CoreGraphics
import Testing
@testable import Library

@Test func columnsFitBetweenInsetsAndNeverDropBelowOne() {
    // 8 + 3 * 240 + 2 * 6 + 8 = 748 fits three; 747 fits two.
    #expect(GridGeometry(itemSize: 240, width: 748).columns == 3)
    #expect(GridGeometry(itemSize: 240, width: 747).columns == 2)
    #expect(GridGeometry(itemSize: 480, width: 100).columns == 1)
}

@Test func stepsAreFiveAndClamped() {
    #expect(GridGeometry.itemSizes == [120, 160, 240, 320, 480])
    #expect(GridGeometry.clampedStep(-3) == 0)
    #expect(GridGeometry.clampedStep(9) == 4)
}

@Test func visibleRangeCoversPartlyVisibleRows() {
    let g = GridGeometry(itemSize: 100, width: 330)   // 3 columns, pitch 106
    #expect(g.columns == 3)
    #expect(g.visibleRange(offset: 0, height: 200, count: 100) == 0..<6)
    // Scrolled so row 1 is cut at the top and row 3 starts at the bottom edge.
    #expect(g.visibleRange(offset: 120, height: 200, count: 100) == 3..<9)
    #expect(g.visibleRange(offset: 0, height: 200, count: 4) == 0..<4)
    #expect(g.visibleRange(offset: 0, height: 200, count: 0).isEmpty)
    #expect(g.visibleRange(offset: 5000, height: 200, count: 4).isEmpty || g.visibleRange(offset: 5000, height: 200, count: 4).upperBound == 4)
}

@Test func arrowKeysMoveByPhotoAndByRow() {
    let g = GridGeometry(itemSize: 100, width: 330)   // 3 columns; 8 photos: rows 0-2, 3-5, 6-7
    #expect(g.moved(from: 4, .left, count: 8) == 3)
    #expect(g.moved(from: 3, .left, count: 8) == 2)   // wraps to the row above
    #expect(g.moved(from: 0, .left, count: 8) == 0)
    #expect(g.moved(from: 7, .right, count: 8) == 7)
    #expect(g.moved(from: 4, .up, count: 8) == 1)
    #expect(g.moved(from: 1, .up, count: 8) == 1)
    #expect(g.moved(from: 4, .down, count: 8) == 7)
    #expect(g.moved(from: 5, .down, count: 8) == 7)   // short last row: its last photo
    #expect(g.moved(from: 7, .down, count: 8) == 7)   // already on the last row
    #expect(g.moved(from: 6, .down, count: 8) == 6)
}

@Test func contentHeightHasNoTrailingSpacing() {
    let g = GridGeometry(itemSize: 100, width: 330)
    #expect(g.contentHeight(count: 0) == 0)
    let expected: CGFloat = 328
    #expect(g.contentHeight(count: 7) == expected)
}

@Test func prefetchFillsVisibleThenTravelDirection() {
    let down = GridPrefetch.order(visible: 6..<12, count: 100, columns: 3, direction: .down, rowsAhead: 2, rowsBehind: 1)
    #expect(down == [6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 5, 4, 3])
    let up = GridPrefetch.order(visible: 6..<12, count: 100, columns: 3, direction: .up, rowsAhead: 2, rowsBehind: 1)
    #expect(up == [6, 7, 8, 9, 10, 11, 5, 4, 3, 2, 1, 0, 12, 13, 14])
}

@Test func prefetchStaysInsideTheFolder() {
    let order = GridPrefetch.order(visible: 0..<4, count: 6, columns: 2, direction: .down)
    #expect(order == [0, 1, 2, 3, 4, 5])
    #expect(GridPrefetch.order(visible: 0..<0, count: 6, columns: 2, direction: .down).isEmpty)
}

@Test func gridLeavesRoomAtTheRightForTheScrollerAndCountsColumnsWithIt() {
    // 8 + 3 * 240 + 2 * 6 + 18 = 758 fits three; 757 fits two (the arrow keys and the layout must agree).
    #expect(GridGeometry.grid(itemSize: 240, width: 758).columns == 3)
    #expect(GridGeometry.grid(itemSize: 240, width: 757).columns == 2)
    #expect(GridGeometry.grid(itemSize: 240, width: 758).trailingInset == 18)
    // Without a trailing inset of its own the right side is as wide as the left.
    #expect(GridGeometry(itemSize: 240, width: 748).trailingInset == 8)
}

@Test func cellsSpreadOverTheRowAndTheRowsStepByTheirPitch() {
    // The numbers a flow layout gave on a 1,640 pt wide window with 120 pt cells (P-08: GridLayout must not move a cell).
    let g = GridGeometry.grid(itemSize: 120, width: 1640)
    #expect(g.columns == 12)
    #expect(abs(g.columnGap - 15.818181818) < 1e-6)
    #expect(g.frame(of: 0) == CGRect(x: 8, y: 8, width: 120, height: 120))
    #expect(abs(g.frame(of: 1).minX - 143.818181818) < 1e-6)
    #expect(abs(g.frame(of: 11).maxX - (1640 - 18)) < 1e-6)
    #expect(g.frame(of: 12) == CGRect(x: 8, y: 134, width: 120, height: 120))
    #expect(g.contentHeight(count: 840) == 8830)
    // One column: no gap to spread.
    #expect(GridGeometry.grid(itemSize: 480, width: 300).columnGap == 6)
}

@Test func indicesInARectAreTheRowsItTouches() {
    let g = GridGeometry(itemSize: 100, width: 330)   // 3 columns, pitch 106
    #expect(g.indices(in: CGRect(x: 0, y: 120, width: 330, height: 200), count: 100) == 3..<9)
    #expect(g.indices(in: CGRect(x: 0, y: 0, width: 330, height: 200), count: 4) == 0..<4)
}
