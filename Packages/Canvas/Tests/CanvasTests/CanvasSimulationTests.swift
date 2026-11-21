import CoreGraphics
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
