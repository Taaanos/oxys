import CoreGraphics
import Testing
@testable import Canvas

@Suite struct ZoomGeometryTests {
    @Test func swappingPreviewForRawKeepsTheSameOnScreenSize() {
        // 100% of a 1620 px preview shows 1620 px; the same width of a 6000 px RAW is 27%, and back.
        let toRaw = ZoomGeometry.scale(1, keepingSizeFrom: 1620, to: 6000)
        #expect(abs(toRaw - 0.27) < 1e-9)
        #expect(abs(ZoomGeometry.scale(toRaw, keepingSizeFrom: 6000, to: 1620) - 1) < 1e-9)
        #expect(ZoomGeometry.scale(2, keepingSizeFrom: 0, to: 6000) == 2)
    }

    let image = CGSize(width: 6000, height: 4000)
    let view = CGSize(width: 3000, height: 2000)

    @Test func aScaleBelowFitBecomesFit() {
        let image = CGSize(width: 3000, height: 4000), view = CGSize(width: 2000, height: 2000)   // Fit is 0.5
        #expect(ZoomGeometry.normalized(.scale(0.12), imageSize: image, viewSize: view, oneToOne: 1) == .fit)
        #expect(ZoomGeometry.normalized(.scale(0.5), imageSize: image, viewSize: view, oneToOne: 1) == .fit)
        #expect(ZoomGeometry.normalized(.scale(1), imageSize: image, viewSize: view, oneToOne: 1) == .scale(1))
        #expect(ZoomGeometry.normalized(.fit, imageSize: image, viewSize: view, oneToOne: 1) == .fit)
    }

    @Test func oneToOneIsExactAtTheDefaultMode() {
        #expect(ZoomGeometry.oneToOneScale(modePixelWidth: 3024, nativePixelWidth: 3024) == 1)
    }

    @Test func scaledModeRendersMorePixelsThanThePanelHas() {
        // "More Space": 3600 rendered pixels resampled onto a 3024 pixel panel.
        let s = ZoomGeometry.oneToOneScale(modePixelWidth: 3600, nativePixelWidth: 3024)
        #expect(abs(s - 3600.0 / 3024.0) < 1e-9)
        #expect(ZoomGeometry.oneToOneScale(modePixelWidth: 0, nativePixelWidth: 3024) == 1)
    }

    @Test func oneToOneShowsEveryImagePixelOnOneDrawablePixel() {
        let rect = ZoomGeometry.rect(imageSize: image, viewSize: view, scale: 1, center: CGPoint(x: 0.5, y: 0.5))
        #expect(rect.size == image)
        #expect(rect.origin.x == -1500 && rect.origin.y == -1000)
        #expect(rect.origin.x == rect.origin.x.rounded())
    }

    @Test func pointUnderPointerStaysUnderPointer() {
        // Fit rect for this image in this view, then zoom to 1:1 with the pointer on an arbitrary spot.
        let fit = ZoomGeometry.fitScale(imageSize: image, viewSize: view)
        let fitRect = ZoomGeometry.rect(imageSize: image, viewSize: view, scale: fit, center: CGPoint(x: 0.5, y: 0.5))
        let pointer = CGPoint(x: 1200, y: 700)
        let u = CGPoint(x: (pointer.x - fitRect.minX) / fitRect.width, y: (pointer.y - fitRect.minY) / fitRect.height)
        let center = ZoomGeometry.center(keeping: u, under: pointer, imageSize: image, viewSize: view, scale: 1)
        let zoomed = ZoomGeometry.rect(imageSize: image, viewSize: view, scale: 1, center: center)
        let under = CGPoint(x: zoomed.minX + u.x * zoomed.width, y: zoomed.minY + u.y * zoomed.height)
        #expect(abs(under.x - pointer.x) <= 1 && abs(under.y - pointer.y) <= 1)
    }

    @Test func neverShowsAGapAtAnEdge() {
        let corner = ZoomGeometry.rect(imageSize: image, viewSize: view, scale: 1, center: CGPoint(x: 0, y: 1))
        #expect(corner.minX == 0 && corner.maxY == view.height)
        let far = ZoomGeometry.rect(imageSize: image, viewSize: view, scale: 1, center: CGPoint(x: 5, y: -5))
        #expect(far.maxX == view.width && far.minY == 0)
    }

    @Test func smallImageIsCenteredNotPanned() {
        let small = CGSize(width: 1000, height: 500)
        let rect = ZoomGeometry.rect(imageSize: small, viewSize: view, scale: 1, center: CGPoint(x: 0, y: 0))
        #expect(rect.origin == CGPoint(x: 1000, y: 750))
    }

    @Test func centerRoundTrips() {
        let c = CGPoint(x: 0.45, y: 0.6)
        let rect = ZoomGeometry.rect(imageSize: image, viewSize: view, scale: 1, center: c)
        let back = ZoomGeometry.center(of: rect, viewSize: view)
        #expect(abs(back.x - c.x) < 0.001 && abs(back.y - c.y) < 0.001)
    }

    @Test func stepsGoFitThenEveryStopAboveFit() {
        let fit: CGFloat = 0.31
        var level = ZoomLevel.fit
        var seen: [ZoomLevel] = [level]
        var current = fit
        while let next = ZoomSteps.next(from: current, fit: fit, direction: .in) {
            seen.append(next)
            current = if case .scale(let s) = next { s } else { fit }
        }
        #expect(seen == [.fit, .scale(0.5), .scale(1), .scale(2), .scale(4)])
        level = .scale(0.5)
        #expect(ZoomSteps.next(from: 0.5, fit: fit, direction: .out) == .fit)
        #expect(ZoomSteps.next(from: fit, fit: fit, direction: .out) == nil)
        _ = level
    }

    @Test func stepsFromBetweenStopsGoToTheNearestInThatDirection() {
        #expect(ZoomSteps.next(from: 1.4, fit: 0.2, direction: .in) == .scale(2))
        #expect(ZoomSteps.next(from: 1.4, fit: 0.2, direction: .out) == .scale(1))
        #expect(ZoomSteps.next(from: 0.1, fit: 0.2, direction: .in) == .fit)
        #expect(ZoomSteps.next(from: 4, fit: 0.2, direction: .in) == nil)
    }

    @Test func aSmallImageHasNoStepsBelowItsFitScale() {
        // Fit upscales a small image to 3x: only 4x is above it.
        #expect(ZoomSteps.next(from: 3, fit: 3, direction: .in) == .scale(4))
        #expect(ZoomSteps.next(from: 4, fit: 3, direction: .out) == .fit)
    }

    @Test func panStopsAtEveryEdge() {
        var center = CGPoint(x: 0.5, y: 0.5)
        for _ in 0..<20 {
            center = ZoomGeometry.panned(center: center, by: CGPoint(x: 700, y: 500), imageSize: image, viewSize: view, scale: 1)
        }
        var rect = ZoomGeometry.rect(imageSize: image, viewSize: view, scale: 1, center: center)
        #expect(rect.minX == 0 && rect.minY == 0)   // looked as far left and up as possible
        for _ in 0..<20 {
            center = ZoomGeometry.panned(center: center, by: CGPoint(x: -700, y: -500), imageSize: image, viewSize: view, scale: 1)
        }
        rect = ZoomGeometry.rect(imageSize: image, viewSize: view, scale: 1, center: center)
        #expect(rect.maxX == view.width && rect.maxY == view.height)
    }

    @Test func panDoesNotWindUpPastAnEdge() {
        // Pushing against the left edge, then back by one step, moves at once.
        var center = CGPoint(x: 0.5, y: 0.5)
        for _ in 0..<50 {
            center = ZoomGeometry.panned(center: center, by: CGPoint(x: 700, y: 0), imageSize: image, viewSize: view, scale: 1)
        }
        let back = ZoomGeometry.panned(center: center, by: CGPoint(x: -100, y: 0), imageSize: image, viewSize: view, scale: 1)
        let rect = ZoomGeometry.rect(imageSize: image, viewSize: view, scale: 1, center: back)
        #expect(rect.minX == -100)
    }

    @Test func panMovesByTheDeltaAndLeavesAnAxisThatFits() {
        let wide = CGSize(width: 6000, height: 1000)
        let c = ZoomGeometry.panned(center: CGPoint(x: 0.5, y: 0.5), by: CGPoint(x: -300, y: 200), imageSize: wide, viewSize: view, scale: 1)
        let rect = ZoomGeometry.rect(imageSize: wide, viewSize: view, scale: 1, center: c)
        #expect(abs(rect.minX - (-1500 - 300)) <= 1)
        #expect(rect.minY == 500)   // 1000 px tall in a 2000 px view stays centered
    }

    @Test func stickyCenterSurvivesAnotherOrientation() {
        // The same normalized center on a portrait frame lands on the same relative spot.
        let c = CGPoint(x: 0.45, y: 0.6)
        let portrait = CGSize(width: 4000, height: 6000)
        let rect = ZoomGeometry.rect(imageSize: portrait, viewSize: view, scale: 1, center: c)
        let back = ZoomGeometry.center(of: rect, viewSize: view)
        #expect(abs(back.x - c.x) < 0.001 && abs(back.y - c.y) < 0.001)
    }
}

@Suite struct ZoomAnchorTests {
    let view = CGSize(width: 3000, height: 2000)
    let pointer = ZoomAnchor.Spot(image: CGPoint(x: 0.2, y: 0.3), view: CGPoint(x: 700, y: 500))
    let focus = CGPoint(x: 0.75, y: 0.4)

    @Test func pointerOverTheImageWinsOverTheFocusPoint() {
        #expect(ZoomAnchor.resolve(pointer: pointer, focus: focus, leavingFit: true, viewSize: view) == pointer)
    }

    @Test func pointerOffTheImageUsesTheFocusPointAtTheMiddle() {
        let spot = ZoomAnchor.resolve(pointer: nil, focus: focus, leavingFit: true, viewSize: view)
        #expect(spot == ZoomAnchor.Spot(image: focus, view: CGPoint(x: 1500, y: 1000)))
    }

    @Test func withoutFocusDataTheMiddleStaysPut() {
        #expect(ZoomAnchor.resolve(pointer: nil, focus: nil, leavingFit: true, viewSize: view) == nil)
    }

    @Test func zoomingWhileAlreadyZoomedDoesNotJumpToTheFocusPoint() {
        #expect(ZoomAnchor.resolve(pointer: nil, focus: focus, leavingFit: false, viewSize: view) == nil)
    }

    @Test func aFocusPointOutsideTheImageIsIgnored() {
        #expect(ZoomAnchor.resolve(pointer: nil, focus: CGPoint(x: 1.2, y: 0.5), leavingFit: true, viewSize: view) == nil)
    }

    @Test func theFocusPointLandsInTheMiddleOfTheViewAt1to1() {
        let image = CGSize(width: 6000, height: 4000)
        let spot = ZoomAnchor.resolve(pointer: nil, focus: focus, leavingFit: true, viewSize: view)!
        let center = ZoomGeometry.center(keeping: spot.image, under: spot.view, imageSize: image, viewSize: view, scale: 1)
        let rect = ZoomGeometry.rect(imageSize: image, viewSize: view, scale: 1, center: center)
        let onScreen = CGPoint(x: rect.minX + focus.x * rect.width, y: rect.minY + focus.y * rect.height)
        #expect(abs(onScreen.x - 1500) <= 1 && abs(onScreen.y - 1000) <= 1)
    }
}
