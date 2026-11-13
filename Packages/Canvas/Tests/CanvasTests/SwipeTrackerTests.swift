import Testing
@testable import Canvas

@Test func swipeFiresOncePerGestureAndIgnoresMomentum() {
    var tracker = SwipeTracker(threshold: 40)
    #expect(tracker.update(phase: .began, dx: -10, dy: 0, isMomentum: false) == nil)
    #expect(tracker.update(phase: .changed, dx: -15, dy: 2, isMomentum: false) == nil)
    #expect(tracker.update(phase: .changed, dx: -20, dy: 2, isMomentum: false) == 1)
    // Further deltas and momentum events in the same gesture do not fire again.
    #expect(tracker.update(phase: .changed, dx: -50, dy: 0, isMomentum: false) == nil)
    #expect(tracker.update(phase: .ended, dx: 0, dy: 0, isMomentum: false) == nil)
    #expect(tracker.update(phase: .changed, dx: -80, dy: 0, isMomentum: true) == nil)
    // A new gesture to the right triggers previous (-1).
    #expect(tracker.update(phase: .began, dx: 5, dy: 0, isMomentum: false) == nil)
    #expect(tracker.update(phase: .changed, dx: 45, dy: 3, isMomentum: false) == -1)
}

@Test func verticalScrollDoesNotTriggerHorizontalSwipe() {
    var tracker = SwipeTracker(threshold: 40)
    #expect(tracker.update(phase: .began, dx: -5, dy: 30, isMomentum: false) == nil)
    #expect(tracker.update(phase: .changed, dx: -40, dy: 60, isMomentum: false) == nil)
    #expect(tracker.update(phase: .ended, dx: 0, dy: 0, isMomentum: false) == nil)
}

@Test func pinchTrackerFiresOncePerGesture() {
    var tracker = PinchNavigationTracker(threshold: 0.22)
    #expect(tracker.update(phase: .began, magnification: -0.05) == nil)
    #expect(tracker.update(phase: .changed, magnification: -0.10) == nil)
    #expect(tracker.update(phase: .changed, magnification: -0.10) == -1)
    #expect(tracker.update(phase: .changed, magnification: -0.20) == nil)
    #expect(tracker.update(phase: .ended, magnification: 0) == nil)
    #expect(tracker.update(phase: .began, magnification: 0.10) == nil)
    #expect(tracker.update(phase: .changed, magnification: 0.15) == 1)
}
