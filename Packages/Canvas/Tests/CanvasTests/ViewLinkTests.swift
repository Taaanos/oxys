import CoreGraphics
import Testing
@testable import Canvas

@Suite struct ViewLinkTests {
    private func state(_ scale: CGFloat, _ x: CGFloat, _ y: CGFloat) -> ViewState {
        ViewState(level: .scale(scale), center: CGPoint(x: x, y: y))
    }

    @Test func aFreshLinkShowsTheSameRelativePointAtTheSameZoom() {
        let link = ViewLink()
        let leader = state(1, 0.3, 0.7)
        #expect(link.follower(of: leader) == leader)
    }

    @Test func fitHasNoSpot() {
        let link = ViewLink(offset: CGPoint(x: 0.1, y: 0.1))
        #expect(link.follower(of: ViewState(level: .fit)) == ViewState(level: .fit))
        // Linking while either side is at Fit keeps no offset.
        #expect(ViewLink(leader: ViewState(level: .fit), follower: state(1, 0.4, 0.4)).offset == .zero)
        #expect(ViewLink(leader: state(1, 0.4, 0.4), follower: ViewState(level: .fit)).offset == .zero)
        // Different zooms: the same.
        #expect(ViewLink(leader: state(1, 0.4, 0.4), follower: state(2, 0.5, 0.5)).offset == .zero)
    }

    @Test func relinkingKeepsTheOffsetPanningLeftBetween() {
        let leader = state(1, 0.50, 0.50)
        let follower = state(1, 0.52, 0.49)
        let link = ViewLink(leader: leader, follower: follower)
        // The follower keeps its place, and then moves with the leader by the same amount.
        let before = link.follower(of: leader)
        #expect(abs(before.center.x - 0.52) < 1e-9 && abs(before.center.y - 0.49) < 1e-9)
        let moved = link.follower(of: state(1, 0.60, 0.40))
        #expect(abs(moved.center.x - 0.62) < 1e-9 && abs(moved.center.y - 0.39) < 1e-9)
    }

    @Test func theFollowerTakesTheLeadersZoom() {
        let link = ViewLink(offset: CGPoint(x: 0.02, y: 0))
        #expect(link.follower(of: state(2, 0.5, 0.5)).level == .scale(2))
    }

    @Test func theFollowerStaysInsideThePicture() {
        let link = ViewLink(offset: CGPoint(x: 0.3, y: -0.3))
        let out = link.follower(of: state(1, 0.9, 0.1))
        #expect(out.center == CGPoint(x: 1, y: 0))
    }

    @Test func reversingGivesTheOtherSidesView() {
        let a = state(1, 0.40, 0.60), b = state(1, 0.45, 0.58)
        let link = ViewLink(leader: a, follower: b)
        let back = link.reversed.follower(of: b)
        #expect(abs(back.center.x - 0.40) < 1e-9 && abs(back.center.y - 0.60) < 1e-9)
    }
}
