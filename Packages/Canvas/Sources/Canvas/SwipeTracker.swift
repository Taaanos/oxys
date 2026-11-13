import CoreGraphics

/// Coalesces trackpad scroll-wheel deltas into at most one horizontal step (`-1` previous, `+1` next) per gesture (V-34).
public struct SwipeTracker: Sendable {
    public enum Phase: Sendable {
        case began, changed, ended, cancelled
    }

    private var deltaX: CGFloat = 0
    private var absDeltaY: CGFloat = 0
    private var triggered = false
    private let threshold: CGFloat

    public init(threshold: CGFloat = 40) {
        self.threshold = threshold
    }

    public mutating func reset() {
        deltaX = 0
        absDeltaY = 0
        triggered = false
    }

    /// Feeds one trackpad scroll sample (ignoring momentum events). Returns `-1` (previous) or `+1` (next) once per gesture.
    public mutating func update(phase: Phase, dx: CGFloat, dy: CGFloat, isMomentum: Bool) -> Int? {
        if isMomentum { return nil }
        switch phase {
        case .began:
            reset()
            deltaX = dx
            absDeltaY = abs(dy)
            return nil
        case .changed:
            guard !triggered else { return nil }
            deltaX += dx
            absDeltaY += abs(dy)
            guard abs(deltaX) >= threshold, abs(deltaX) > absDeltaY * 1.2 else { return nil }
            triggered = true
            return deltaX < 0 ? 1 : -1
        case .ended, .cancelled:
            reset()
            return nil
        }
    }
}

/// Accumulates magnify gesture deltas and fires once when a pinch crosses `threshold` (V-34).
public struct PinchNavigationTracker: Sendable {
    private var total: CGFloat = 0
    private var triggered = false
    private let threshold: CGFloat

    public init(threshold: CGFloat = 0.22) {
        self.threshold = threshold
    }

    public mutating func reset() {
        total = 0
        triggered = false
    }

    /// Returns `-1` on pinch-in (below `-threshold`) or `+1` on pinch-out (above `+threshold`), at most once per gesture.
    public mutating func update(phase: SwipeTracker.Phase, magnification: CGFloat) -> Int? {
        switch phase {
        case .began:
            reset()
            total = magnification
            return nil
        case .changed:
            guard !triggered else { return nil }
            total += magnification
            if total <= -threshold {
                triggered = true
                return -1
            }
            if total >= threshold {
                triggered = true
                return 1
            }
            return nil
        case .ended, .cancelled:
            reset()
            return nil
        }
    }
}
