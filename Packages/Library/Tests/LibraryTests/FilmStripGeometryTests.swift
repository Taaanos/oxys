import CoreGraphics
import Testing
@testable import Library

private let strip = FilmStripGeometry(width: 800)   // pitch 84, inset 8

@Test func bandHoldsTheCellAndItsSpace() {
    #expect(FilmStripGeometry.cellSize == 80)
    #expect(FilmStripGeometry.bandHeight == 96)
}

@Test func activeCellIsCenteredInTheMiddleOfTheList() {
    let offset = strip.offset(centering: 50, count: 100)
    let middle = strip.origin(of: 50, count: 100) + 40
    #expect(middle - offset == 400)
}

@Test func stripStopsAtTheStartAndTheEnd() {
    #expect(strip.offset(centering: 0, count: 100) == 0)
    #expect(strip.offset(centering: 2, count: 100) == 0)
    let last = strip.documentWidth(count: 100) - 800
    #expect(strip.offset(centering: 99, count: 100) == last)
    #expect(strip.offset(centering: 97, count: 100) == last)
    // Out-of-range indices are clamped, not trusted.
    #expect(strip.offset(centering: -5, count: 100) == 0)
    #expect(strip.offset(centering: 500, count: 100) == last)
}

@Test func aShortListIsCenteredAndNeverScrolls() {
    for count in 1...4 {
        #expect(strip.offset(centering: count - 1, count: count) == 0)
        #expect(strip.documentWidth(count: count) == 800)
        let first = strip.origin(of: 0, count: count)
        let end = strip.origin(of: count - 1, count: count) + 80
        #expect(abs(first - (800 - end)) < 0.001)   // the same space on both sides
    }
    #expect(strip.visibleRange(offset: 0, count: 3) == 0..<3)
}

@Test func emptyListHasNothingToShow() {
    #expect(strip.offset(centering: 0, count: 0) == 0)
    #expect(strip.visibleRange(offset: 0, count: 0).isEmpty)
    #expect(strip.order(visible: 0..<0, count: 0, center: 0).isEmpty)
    #expect(strip.contentWidth(count: 0) == 0)
}

@Test func narrowStripIsStillUsable() {
    let narrow = FilmStripGeometry(width: 0)
    #expect(narrow.visibleRange(offset: 0, count: 10).isEmpty)
    #expect(narrow.offset(centering: 5, count: 10) >= 0)
}

@Test func visibleRangeCoversPartlyVisibleCells() {
    #expect(strip.visibleRange(offset: 0, count: 100) == 0..<10)
    // Cell 10 starts at 8 + 840 = 848; an offset of 100 shows 100..<900, so cells 1 through 10.
    #expect(strip.visibleRange(offset: 100, count: 100) == 1..<11)
    let end = strip.documentWidth(count: 100) - 800
    #expect(strip.visibleRange(offset: end, count: 100).upperBound == 100)
}

@Test func clampKeepsAWheelScrollInsideTheStrip() {
    #expect(strip.clamp(-300, count: 100) == 0)
    #expect(strip.clamp(1_000_000, count: 100) == strip.documentWidth(count: 100) - 800)
    #expect(strip.clamp(500, count: 100) == 500)
    #expect(strip.clamp(500, count: 3) == 0)
}

@Test func loadsGoToTheNearestCellsFirstWithAMargin() {
    let order = strip.order(visible: 40..<50, count: 100, center: 45, margin: 2)
    #expect(order.count == 14)          // 38..<52
    #expect(order.first == 45)
    #expect(Set(order) == Set(38..<52))
    // Nearer cells never come after farther ones.
    let distances = order.map { abs($0 - 45) }
    #expect(distances == distances.sorted())
}

@Test func marginStopsAtTheEndsOfTheList() {
    let order = strip.order(visible: 0..<10, count: 12, center: 0, margin: 4)
    #expect(Set(order) == Set(0..<12))
    #expect(order.first == 0)
}
