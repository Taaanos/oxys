import CoreGraphics

/// Coalesces trackpad scroll-wheel deltas into at most one horizontal step (`-1` previous, `+1` next) per gesture (V-34).
public struct SwipeTracker: Sendable {
    public enum Phase: Sendable {
        case began, changed, ended, cancelled
    }

    private enum State: Sendable {
        case idle
        case tracking(deltaX: CGFloat, absDeltaY: CGFloat)
        case triggered
    }

    private var state: State = .idle
    private let threshold: CGFloat

    public init(threshold: CGFloat = 40) {
        self.threshold = threshold
    }

    public mutating func reset() {
        state = .idle
    }

    /// Feeds one trackpad scroll sample (ignoring momentum events). Returns `-1` (previous) or `+1` (next) once per gesture.
    public mutating func update(phase: Phase, dx: CGFloat, dy: CGFloat, isMomentum: Bool) -> Int? {
        if isMomentum { return nil }
        switch phase {
        case .began:
            state = .tracking(deltaX: dx, absDeltaY: abs(dy))
            return nil
        case .changed:
            let prevX: CGFloat
            let prevY: CGFloat
            switch state {
            case .triggered: return nil
            case .idle: (prevX, prevY) = (0, 0)
            case .tracking(let x, let y): (prevX, prevY) = (x, y)
            }
            let x = prevX + dx
            let y = prevY + abs(dy)
            guard abs(x) >= threshold, abs(x) > y * 1.2 else {
                state = .tracking(deltaX: x, absDeltaY: y)
                return nil
            }
            state = .triggered
            return x < 0 ? 1 : -1
        case .ended, .cancelled:
            state = .idle
            return nil
        }
    }
}

/// Accumulates magnify gesture deltas and fires once when a pinch crosses `threshold` (V-34).
public struct PinchNavigationTracker: Sendable {
    private enum State: Sendable {
        case idle
        case tracking(total: CGFloat)
        case triggered
    }

    private var state: State = .idle
    private let threshold: CGFloat

    public init(threshold: CGFloat = 0.22) {
        self.threshold = threshold
    }

    public mutating func reset() {
        state = .idle
    }

    /// Returns `-1` on pinch-in (below `-threshold`) or `+1` on pinch-out (above `+threshold`), at most once per gesture.
    public mutating func update(phase: SwipeTracker.Phase, magnification: CGFloat) -> Int? {
        switch phase {
        case .began:
            state = .tracking(total: magnification)
            return nil
        case .changed:
            let prev: CGFloat
            switch state {
            case .triggered: return nil
            case .idle: prev = 0
            case .tracking(let total): prev = total
            }
            let total = prev + magnification
            if total <= -threshold {
                state = .triggered
                return -1
            }
            if total >= threshold {
                state = .triggered
                return 1
            }
            state = .tracking(total: total)
            return nil
        case .ended, .cancelled:
            state = .idle
            return nil
        }
    }
}
