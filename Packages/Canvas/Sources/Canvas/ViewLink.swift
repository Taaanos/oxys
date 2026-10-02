import CoreGraphics

/// The part of a picture a canvas shows: Fit, or a scale and the picture point (0...1, top-left origin) at the
/// middle of the view (V-09). The scale is in physical screen pixels per picture pixel, so two canvases with the
/// same level show the same magnification.
public struct ViewState: Sendable, Equatable {
    public var level: ZoomLevel
    public var center: CGPoint

    public init(level: ZoomLevel, center: CGPoint = CGPoint(x: 0.5, y: 0.5)) {
        self.level = level
        self.center = center
    }
}

/// How two linked canvases move together (V-09). The follower shows the leader's zoom, and the same relative
/// point moved by `offset`. The offset is what separate panning left between them, so relinking keeps it
/// (V-09/Q1): it lines up two handheld frames that are shifted a little.
public struct ViewLink: Sendable, Equatable {
    /// Follower's center minus the leader's, in picture fractions.
    public var offset: CGPoint

    public init(offset: CGPoint = .zero) { self.offset = offset }

    /// The link that keeps `follower` where it is against `leader`. At Fit there is no spot, and at two different
    /// zooms the offset means nothing, so nothing is kept (the follower then takes the leader's zoom).
    public init(leader: ViewState, follower: ViewState) {
        if leader.level.isFit || leader.level != follower.level {
            offset = .zero
        } else {
            offset = CGPoint(x: follower.center.x - leader.center.x, y: follower.center.y - leader.center.y)
        }
    }

    /// The same link seen from the other side.
    public var reversed: ViewLink { ViewLink(offset: CGPoint(x: -offset.x, y: -offset.y)) }

    /// What the follower shows when the leader shows `leader`. The center stays inside the picture.
    public func follower(of leader: ViewState) -> ViewState {
        guard !leader.level.isFit else { return ViewState(level: .fit) }
        func clamp(_ v: CGFloat) -> CGFloat { min(max(v, 0), 1) }
        return ViewState(level: leader.level, center: CGPoint(x: clamp(leader.center.x + offset.x), y: clamp(leader.center.y + offset.y)))
    }
}
