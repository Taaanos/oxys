import CoreGraphics
import ImageIO
import Testing
@testable import Canvas

// MARK: - Deterministic PRNG (SplitMix64)

private struct SeededRNG {
    private var state: UInt64

    init(seed: UInt64) { self.state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    mutating func cgFloat(in range: ClosedRange<CGFloat>) -> CGFloat {
        let u = CGFloat(next() & 0x001F_FFFF_FFFF_FFFF) / CGFloat(0x0020_0000_0000_0000)
        return range.lowerBound + u * (range.upperBound - range.lowerBound)
    }

    mutating func pick<T>(_ items: [T]) -> T {
        items[Int(next() % UInt64(items.count))]
    }
}

private func hex(_ seed: UInt64) -> String { "0x" + String(seed, radix: 16, uppercase: true) }

// MARK: - Suite 1: FitGeometry & ZoomGeometry Property Tests

@Suite struct CanvasGeometryPropertyTests {
    @Test(arguments: [UInt64(0xA001), 0xA002, 0xA003, 0xA004, 0xA005, 0xA006])
    func fitGeometryCentersPreservesAspectAndStaysInBounds(seed: UInt64) {
        var rng = SeededRNG(seed: seed)
        let backingScales: [CGFloat] = [1, 2, 3]

        for step in 0..<300 {
            let img = CGSize(width: rng.cgFloat(in: 50...10_000), height: rng.cgFloat(in: 50...10_000))
            let view = CGSize(width: rng.cgFloat(in: 100...4000), height: rng.cgFloat(in: 100...3000))
            let bs = rng.pick(backingScales)

            let rect = FitGeometry.fitRect(imageSize: img, viewSize: view, backingScale: bs)
            let tol = 1.0 / bs + 1e-6

            #expect(rect.width > 0 && rect.height > 0, "seed=\(hex(seed)) step=\(step): non-positive fitRect")
            #expect(rect.minX >= -tol && rect.minY >= -tol, "seed=\(hex(seed)) step=\(step): negative origin")
            #expect(rect.maxX <= view.width + tol && rect.maxY <= view.height + tol,
                    "seed=\(hex(seed)) step=\(step): fitRect exceeds viewSize")

            // Centered within one snapped pixel
            #expect(abs(rect.midX - view.width / 2) <= tol, "seed=\(hex(seed)) step=\(step): not horizontally centered")
            #expect(abs(rect.midY - view.height / 2) <= tol, "seed=\(hex(seed)) step=\(step): not vertically centered")

            // At least one dimension touches the view edge (within snap tolerance)
            let touchesW = abs(rect.width - view.width) <= 2 * tol
            let touchesH = abs(rect.height - view.height) <= 2 * tol
            #expect(touchesW || touchesH, "seed=\(hex(seed)) step=\(step): fitRect does not fill either axis")
        }
    }

    @Test(arguments: [UInt64(0xB101), 0xB102, 0xB103, 0xB104, 0xB105, 0xB106])
    func zoomGeometryClampsEdgesRoundTripsAndStepsMonotonically(seed: UInt64) {
        var rng = SeededRNG(seed: seed)

        for step in 0..<300 {
            let img = CGSize(width: rng.cgFloat(in: 200...9000), height: rng.cgFloat(in: 200...6000))
            let view = CGSize(width: rng.cgFloat(in: 200...3840), height: rng.cgFloat(in: 200...2160))
            let fit = ZoomGeometry.fitScale(imageSize: img, viewSize: view)
            let lo = min(max(0.05, fit * 0.5), ZoomSteps.maxScale)
            let hi = max(ZoomSteps.maxScale, fit * 2.0)
            let scale = rng.cgFloat(in: lo...hi)
            let center = CGPoint(x: rng.cgFloat(in: -0.5...1.5), y: rng.cgFloat(in: -0.5...1.5))

            let r = ZoomGeometry.rect(imageSize: img, viewSize: view, scale: scale, center: center)
            #expect(r.width.isFinite && r.height.isFinite && r.minX.isFinite && r.minY.isFinite)

            // No-gap / centering invariant on each axis
            if r.width <= view.width {
                #expect(abs(r.minX - ((view.width - r.width) / 2).rounded()) <= 1e-6,
                        "seed=\(hex(seed)) step=\(step): narrow width not centered")
            } else {
                #expect(r.minX <= 0 && r.maxX >= view.width - 1.0,
                        "seed=\(hex(seed)) step=\(step): horizontal gap exposed (minX=\(r.minX), maxX=\(r.maxX), viewW=\(view.width))")
            }
            if r.height <= view.height {
                #expect(abs(r.minY - ((view.height - r.height) / 2).rounded()) <= 1e-6,
                        "seed=\(hex(seed)) step=\(step): short height not centered")
            } else {
                #expect(r.minY <= 0 && r.maxY >= view.height - 1.0,
                        "seed=\(hex(seed)) step=\(step): vertical gap exposed (minY=\(r.minY), maxY=\(r.maxY), viewH=\(view.height))")
            }

            // Panning by zero is idempotent after one clamp, and panning by arbitrary delta stays finite with no gaps.
            let delta = CGPoint(x: rng.cgFloat(in: -5000...5000), y: rng.cgFloat(in: -5000...5000))
            let panned = ZoomGeometry.panned(center: center, by: delta, imageSize: img, viewSize: view, scale: scale)
            let pannedRect = ZoomGeometry.rect(imageSize: img, viewSize: view, scale: scale, center: panned)
            let repannedZero = ZoomGeometry.panned(center: panned, by: .zero, imageSize: img, viewSize: view, scale: scale)
            let repannedRect = ZoomGeometry.rect(imageSize: img, viewSize: view, scale: scale, center: repannedZero)
            #expect(abs(pannedRect.minX - repannedRect.minX) <= 1 && abs(pannedRect.minY - repannedRect.minY) <= 1,
                    "seed=\(hex(seed)) step=\(step): zero pan drifted")

            // Normalized zoom never leaves a `.scale` smaller than Fit.
            let oneToOne = rng.pick([CGFloat(1.0), 1.5, 2.0])
            let norm = ZoomGeometry.normalized(.scale(scale), imageSize: img, viewSize: view, oneToOne: oneToOne)
            if case .scale(let s) = norm {
                #expect(s * oneToOne > fit, "seed=\(hex(seed)) step=\(step): normalized scale below fit")
            }

            // ZoomSteps.next(.in) is strictly increasing and terminates in <= stops.count + 1 steps.
            var cur = fit
            var stepsIn = 0
            while let next = ZoomSteps.next(from: cur, fit: fit, direction: .in) {
                stepsIn += 1
                #expect(stepsIn <= ZoomSteps.stops.count + 1, "seed=\(hex(seed)) step=\(step): zoom-in loop did not terminate")
                if case .scale(let s) = next {
                    #expect(s > cur, "seed=\(hex(seed)) step=\(step): zoom-in not strictly increasing")
                    cur = s
                } else {
                    cur = fit
                }
            }

            // ZoomSteps.next(.out) from maxScale is strictly decreasing and ends at .fit then nil.
            var outCur = ZoomSteps.maxScale
            var stepsOut = 0
            var reachedFit = false
            while let next = ZoomSteps.next(from: outCur, fit: fit, direction: .out) {
                stepsOut += 1
                #expect(stepsOut <= ZoomSteps.stops.count + 1, "seed=\(hex(seed)) step=\(step): zoom-out loop did not terminate")
                switch next {
                case .scale(let s):
                    #expect(s < outCur, "seed=\(hex(seed)) step=\(step): zoom-out not strictly decreasing")
                    outCur = s
                case .fit:
                    reachedFit = true
                    outCur = fit
                }
            }
            if fit < ZoomSteps.maxScale - 0.01 {
                #expect(reachedFit, "seed=\(hex(seed)) step=\(step): zoom-out from maxScale did not reach .fit")
            }
        }
    }

    @Test(arguments: [UInt64(0xD201), 0xD202, 0xD203, 0xD204])
    func viewLinkReversibilityAndClamping(seed: UInt64) {
        var rng = SeededRNG(seed: seed)
        let eps: CGFloat = 1e-12

        for step in 0..<250 {
            let scale = rng.cgFloat(in: 0.5...4.0)
            let c1 = CGPoint(x: rng.cgFloat(in: 0...1), y: rng.cgFloat(in: 0...1))
            let c2 = CGPoint(x: rng.cgFloat(in: 0...1), y: rng.cgFloat(in: 0...1))
            let leader = ViewState(level: .scale(scale), center: c1)
            let follower = ViewState(level: .scale(scale), center: c2)

            let link = ViewLink(leader: leader, follower: follower)
            let projected = link.follower(of: leader)
            #expect(projected.level == follower.level)
            #expect(abs(projected.center.x - c2.x) < eps && abs(projected.center.y - c2.y) < eps,
                    "seed=\(hex(seed)) step=\(step): ViewLink did not reproduce follower")

            // Double reverse is identity
            let rr = link.reversed.reversed
            #expect(abs(rr.offset.x - link.offset.x) < eps && abs(rr.offset.y - link.offset.y) < eps)

            // Arbitrary leader pan always clamps follower into [0, 1] x [0, 1]
            let movedLeader = ViewState(level: .scale(scale),
                                        center: CGPoint(x: rng.cgFloat(in: 0...1), y: rng.cgFloat(in: 0...1)))
            let movedFollower = link.follower(of: movedLeader)
            #expect((0...1).contains(movedFollower.center.x) && (0...1).contains(movedFollower.center.y),
                    "seed=\(hex(seed)) step=\(step): follower center escaped [0,1]")

            // Fit always maps follower to Fit
            #expect(link.follower(of: ViewState(level: .fit)).level == .fit)
        }
    }
}

// MARK: - Suite 2: SwipeTracker, PinchNavigationTracker & OrientationMap Properties

@Suite struct CanvasGestureAndOrientationTests {
    @Test(arguments: [UInt64(0xE301), 0xE302, 0xE303, 0xE304, 0xE305, 0xE306])
    func swipeAndPinchTrackersFireAtMostOncePerGestureAndIgnoreMomentum(seed: UInt64) {
        var rng = SeededRNG(seed: seed)
        let threshold: CGFloat = 40
        var swipe = SwipeTracker(threshold: threshold)
        var pinch = PinchNavigationTracker(threshold: 0.22)

        for gesture in 0..<100 {
            // 1. Swipe gesture: began -> N changed/momentum events -> ended/cancelled
            var swipeFires = 0
            let initDx = rng.cgFloat(in: -15...15)
            let initDy = rng.cgFloat(in: -15...15)
            #expect(swipe.update(phase: .began, dx: initDx, dy: initDy, isMomentum: false) == nil)

            var sumX = initDx
            var sumAbsY = abs(initDy)
            var expectedFired = false
            let samples = Int(rng.next() % 18) + 2
            for s in 0..<samples {
                let isMomentum = (rng.next() % 4) == 0
                let dx = rng.cgFloat(in: -35...35)
                let dy = rng.cgFloat(in: -35...35)
                let out = swipe.update(phase: .changed, dx: dx, dy: dy, isMomentum: isMomentum)
                if isMomentum {
                    #expect(out == nil, "seed=\(hex(seed)) gesture=\(gesture) sample=\(s): momentum event triggered swipe")
                    continue
                }
                if !expectedFired {
                    sumX += dx
                    sumAbsY += abs(dy)
                    if abs(sumX) >= threshold && abs(sumX) > sumAbsY * 1.2 {
                        expectedFired = true
                        let expectedDir = sumX < 0 ? 1 : -1
                        #expect(out == expectedDir,
                                "seed=\(hex(seed)) gesture=\(gesture) sample=\(s): wrong swipe direction \(String(describing: out)) != \(expectedDir)")
                        swipeFires += 1
                    } else {
                        #expect(out == nil, "seed=\(hex(seed)) gesture=\(gesture) sample=\(s): premature swipe trigger")
                    }
                } else {
                    #expect(out == nil, "seed=\(hex(seed)) gesture=\(gesture) sample=\(s): swipe fired twice in one gesture")
                }
            }
            #expect(swipeFires <= 1)
            let endPhase: SwipeTracker.Phase = (rng.next() % 2) == 0 ? .ended : .cancelled
            #expect(swipe.update(phase: endPhase, dx: 0, dy: 0, isMomentum: false) == nil)

            // 2. Pinch gesture: began -> N changed events -> ended/cancelled
            var pinchFires = 0
            let pInit = rng.cgFloat(in: -0.08...0.08)
            #expect(pinch.update(phase: .began, magnification: pInit) == nil)
            for _ in 0..<samples {
                let mag = rng.cgFloat(in: -0.2...0.2)
                if let dir = pinch.update(phase: .changed, magnification: mag) {
                    #expect(dir == -1 || dir == 1)
                    pinchFires += 1
                }
            }
            #expect(pinchFires <= 1, "seed=\(hex(seed)) gesture=\(gesture): pinch fired \(pinchFires) times in one gesture")
            #expect(pinch.update(phase: endPhase, magnification: 0) == nil)
        }
    }

    @Test(arguments: [UInt64(0xE401), 0xE402, 0xE403, 0xE404])
    func orientationMapBijectsUnitSquareAndPreservesCenter(seed: UInt64) {
        var rng = SeededRNG(seed: seed)
        let orientations: [CGImagePropertyOrientation] = [
            .up, .upMirrored, .down, .downMirrored, .leftMirrored, .right, .rightMirrored, .left,
        ]
        let unitCorners: Set<String> = ["0,0", "1,0", "0,1", "1,1"]
        let eps: CGFloat = 1e-12

        for o in orientations {
            let map = OrientationMap(o)
            // Center (0.5, 0.5) is always fixed
            let mid = map.sourcePoint(displayX: 0.5, displayY: 0.5)
            #expect(abs(mid.x - 0.5) < eps && abs(mid.y - 0.5) < eps, "orientation \(o): center moved to \(mid)")

            // Corners are a bijection of the 4 unit-square corners
            let mappedCorners = Set([map.topLeft, map.topRight, map.bottomLeft, map.bottomRight].map { "\(Int($0.x)),\(Int($0.y))" })
            #expect(mappedCorners == unitCorners, "orientation \(o): corners not a bijection (\(mappedCorners))")

            // Random interior points map strictly into [0, 1]^2 and are distance-preserving (isometry!)
            for step in 0..<50 {
                let a = CGPoint(x: rng.cgFloat(in: 0...1), y: rng.cgFloat(in: 0...1))
                let b = CGPoint(x: rng.cgFloat(in: 0...1), y: rng.cgFloat(in: 0...1))
                let sa = map.sourcePoint(displayX: a.x, displayY: a.y)
                let sb = map.sourcePoint(displayX: b.x, displayY: b.y)
                #expect((-eps...(1 + eps)).contains(sa.x) && (-eps...(1 + eps)).contains(sa.y),
                        "seed=\(hex(seed)) orient=\(o) step=\(step): sourcePoint escaped [0,1]^2")
                let dDisplay = hypot(a.x - b.x, a.y - b.y)
                let dSource = hypot(sa.x - sb.x, sa.y - sb.y)
                #expect(abs(dDisplay - dSource) < 1e-9,
                        "seed=\(hex(seed)) orient=\(o) step=\(step): OrientationMap is not an isometry!")
            }
        }
    }
}
