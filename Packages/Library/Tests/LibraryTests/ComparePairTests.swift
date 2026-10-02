import Foundation
import Testing
@testable import Library

@Suite struct ComparePairTests {
    private let urls = (0..<6).map { URL(fileURLWithPath: "/p/\($0).ARW") }

    private func pair(_ a: Int, _ b: Int, active: ComparePair.Side = .select) -> ComparePair {
        var p = ComparePair.start(selected: [urls[a], urls[b]], current: urls[a], in: urls)!
        if active == .candidate { p.switchSide() }
        return p
    }

    // MARK: entering

    @Test func twoSelectedPhotosCompareThoseTwoInScreenOrder() {
        let p = ComparePair.start(selected: [urls[4], urls[1]], current: urls[4], in: urls)!
        #expect(p.select == urls[1] && p.candidate == urls[4])
        // The active photo was the later one, so the ring starts on the candidate.
        #expect(p.active == .candidate)
    }

    @Test func onePhotoSelectedOrNoneComparesTheActivePhotoWithTheNext() {
        #expect(ComparePair.start(selected: [urls[2]], current: urls[2], in: urls) == ComparePair.start(selected: [], current: urls[2], in: urls))
        let p = ComparePair.start(selected: [], current: urls[2], in: urls)!
        #expect(p.select == urls[2] && p.candidate == urls[3] && p.active == .select)
    }

    @Test func moreThanTwoSelectedFallsBackToTheActivePhotoAndTheNext() {
        let p = ComparePair.start(selected: [urls[0], urls[1], urls[2]], current: urls[1], in: urls)!
        #expect(p.select == urls[1] && p.candidate == urls[2])
    }

    @Test func atTheEndTheCandidateIsThePreviousPhoto() {
        let p = ComparePair.start(selected: [], current: urls[5], in: urls)!
        #expect(p.select == urls[5] && p.candidate == urls[4])
    }

    @Test func oneOrNoPhotoCannotCompare() {
        #expect(ComparePair.start(selected: [], current: urls[0], in: [urls[0]]) == nil)
        #expect(ComparePair.start(selected: [], current: nil, in: []) == nil)
    }

    @Test func activateSetsTheSideAndKeepsThePhotos() {
        var p = pair(0, 3)
        p.activate(.candidate)
        #expect(p.active == .candidate)
        p.activate(.candidate)
        #expect(p.active == .candidate && p.select == urls[0] && p.candidate == urls[3])
        p.activate(.select)
        #expect(p.active == .select)
    }

    // MARK: stepping

    @Test func stepMovesOnlyTheActiveSide() {
        var p = pair(0, 3)
        do { let moved = p.step(.next, in: urls); #expect(moved) }
        #expect(p.select == urls[1] && p.candidate == urls[3])
        p.switchSide()
        do { let moved = p.step(.previous, in: urls); #expect(moved) }
        #expect(p.select == urls[1] && p.candidate == urls[2])
    }

    @Test func stepSkipsThePhotoOnTheOtherSide() {
        var p = pair(0, 1)
        do { let moved = p.step(.next, in: urls); #expect(moved) }
        #expect(p.select == urls[2] && p.candidate == urls[1])
        var q = pair(1, 2, active: .candidate)
        do { let moved = q.step(.previous, in: urls); #expect(moved) }
        #expect(q.candidate == urls[0] && q.select == urls[1])
    }

    @Test func stepStopsAtBothEnds() {
        var p = pair(0, 1, active: .candidate)
        for _ in 0..<10 { p.step(.next, in: urls) }
        #expect(p.candidate == urls[5])
        do { let moved = p.step(.next, in: urls); #expect(!moved) }
        var q = pair(1, 2)
        do { let moved = q.step(.previous, in: urls); #expect(moved) }
        do { let moved = q.step(.previous, in: urls); #expect(!moved) }
        #expect(q.select == urls[0])
    }

    @Test func stepIsBlockedWhenOnlyTheOtherSideIsLeft() {
        let two = Array(urls[0..<2])
        var p = ComparePair.start(selected: [], current: two[0], in: two)!
        do { let moved = p.step(.next, in: two); #expect(!moved) }
        #expect(p.select == two[0])
    }

    @Test func firstAndLastSkipTheOtherSide() {
        var p = pair(0, 5)
        do { let moved = p.step(.last, in: urls); #expect(moved) }
        #expect(p.select == urls[4])
        do { let moved = p.step(.first, in: urls); #expect(moved) }
        #expect(p.select == urls[0])
        var q = pair(0, 3, active: .candidate)
        do { let moved = q.step(.first, in: urls); #expect(moved) }
        #expect(q.candidate == urls[1])
    }

    // MARK: swap, switch, advance

    @Test func swapChangesPlacesAndKeepsTheRingOnItsSide() {
        var p = pair(1, 4, active: .candidate)
        p.swap()
        #expect(p.select == urls[4] && p.candidate == urls[1] && p.active == .candidate)
        #expect(p.activeURL == urls[1])
    }

    @Test func switchSideFlips() {
        var p = pair(1, 4)
        p.switchSide()
        #expect(p.active == .candidate && p.activeURL == urls[4])
        p.switchSide()
        #expect(p.active == .select)
    }

    @Test func advanceKeepsTheCandidateAsTheNewSelect() {
        var p = pair(1, 2, active: .candidate)
        do { let moved = p.advance(in: urls); #expect(moved) }
        #expect(p.select == urls[2] && p.candidate == urls[3] && p.active == .candidate)
        // Steps still skip correctly after an advance.
        do { let moved = p.step(.previous, in: urls); #expect(moved) }
        #expect(p.candidate == urls[1])
    }

    @Test func advanceStopsAtTheEnd() {
        var p = pair(3, 5)
        let before = p
        do { let moved = p.advance(in: urls); #expect(!moved) }
        #expect(p == before)
    }

    // MARK: reject and advance

    @Test func destinationIsTheNextPhotoForTheActiveSideAndNilAtTheEnd() {
        let p = pair(0, 1)
        #expect(p.destination(.next, in: urls) == urls[2])
        let end = pair(0, 5, active: .candidate)
        #expect(end.destination(.next, in: urls) == nil)
    }

    @Test func showPutsAPhotoOnTheActiveSideButNotOntoTheOtherOne() {
        var p = pair(0, 1)
        do { let moved = p.show(urls[1], in: urls); #expect(!moved) }
        do { let moved = p.show(urls[4], in: urls); #expect(moved) }
        #expect(p.select == urls[4] && p.candidate == urls[1])
    }

    // MARK: the list changes

    @Test func aHiddenPhotoLeavesItsSideOnItsNeighbor() {
        let p = pair(1, 3)
        let shown = urls.filter { $0 != urls[1] }          // the select was rejected and the filter hides it
        let fixed = p.reconciled(in: shown)!
        #expect(fixed.select == urls[2] && fixed.candidate == urls[3])
    }

    @Test func twoHiddenPhotosNeverLandOnTheSamePhoto() {
        let p = pair(4, 5)
        let shown = Array(urls[0..<4])
        let fixed = p.reconciled(in: shown)!
        #expect(fixed.select != fixed.candidate)
        #expect(shown.contains(fixed.select) && shown.contains(fixed.candidate))
    }

    @Test func reconcileGivesUpWithFewerThanTwoPhotos() {
        #expect(pair(0, 1).reconciled(in: [urls[0]]) == nil)
    }

    @Test func reconcileLeavesAnIntactPairAlone() {
        let p = pair(2, 4, active: .candidate)
        #expect(p.reconciled(in: urls) == p)
    }
}
