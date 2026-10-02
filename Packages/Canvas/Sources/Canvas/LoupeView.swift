import AppKit
import Diagnostics
import Metal
import QuartzCore

public enum PanDirection: Sendable { case left, right, up, down }

/// One frame at Fit on a neutral dark gray, drawn by Metal. It draws only when something changes (a new image,
/// a resize, a change of display), never on a timer, so an idle window costs no CPU.
@MainActor
public final class LoupeView: NSView {
    /// Neutral gray, the same in light and dark appearance (M-03 open question 1). Tune by eye.
    public static let canvasGray = 0x30 / 255.0

    private let gpu = LoupeGPU.shared
    private var image: PreparedImage?
    private var pendingToken: Perf.Token?
    private var lastDrawableSize = CGSize.zero

    /// Fit or a scale, and the image point (0...1) at the middle of the view while zoomed in.
    public private(set) var zoom = ZoomLevel.fit
    private var zoomCenter = CGPoint(x: 0.5, y: 0.5)
    private var lastInfo: ZoomInfo?
    /// Where Z goes back to after leaving a zoom that was not 1:1 (so tap or hold of Z round-trips).
    private var returnScale: CGFloat?
    /// Called when the zoom level the info strip shows changes.
    public var onZoomChange: ((ZoomInfo?) -> Void)?
    /// Called when a zoom or a pan moves the view (V-09): a key, a pinch, a scroll or a drag. Not called by
    /// ``apply(_:)``, so two linked canvases do not answer each other.
    public var onViewChange: (@MainActor (ViewState) -> Void)?
    /// Where the camera focused in the upright picture (0...1, top-left origin), for the photo on screen; nil when the
    /// file does not say. The zoom goes here when the pointer is not over the image.
    public var focusAnchor: CGPoint?
    /// Sticky zoom (M-15): a different photo keeps the zoom level and the spot. Off, it opens at Fit.
    public var stickyZoom = true
    /// Scales the image's size for zoom geometry. A thumbnail standing in for a preview is smaller than the
    /// preview it stands for; this makes it cover the same area at the same zoom.
    private var sizeFactor: CGFloat = 1
    private var spaceHeld = false {
        didSet { if spaceHeld != oldValue { window?.invalidateCursorRects(for: self) } }
    }
    private var dragging = false
    /// Focus peaking (V-06); nil is off. Set with ``setPeaking(_:token:)``.
    public private(set) var peaking: PeakingStyle?
    private var peakingMask: PeakingMask?
    /// Clipping overlays (V-07); nil is off. Set with ``setClipping(_:token:)``.
    public private(set) var clipping: ClippingStyle?
    private var clippingMask: ClippingMask?
    /// Told, on the main thread, how much of the frame is clipped, or nil when there is nothing to report (overlay
    /// off, a stand-in, no picture). Called once per analysis, not per frame.
    public var onClippingStats: (@MainActor (ClippingStats?) -> Void)?
    /// A thumbnail stand-in is not the picture: peaking on it would flash marks that the real frame then replaces.
    private var isStandIn = false

    private var metalLayer: CAMetalLayer { layer as! CAMetalLayer }

    public override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        setAccessibilityRole(.image)
    }

    public required init?(coder: NSCoder) { fatalError("LoupeView is created in code") }

    public override func makeBackingLayer() -> CALayer {
        let layer = CAMetalLayer()
        layer.device = LoupeGPU.shared?.device
        layer.pixelFormat = LoupeGPU.pixelFormat
        layer.framebufferOnly = true
        layer.isOpaque = true
        layer.backgroundColor = CGColor(gray: Self.canvasGray, alpha: 1)
        return layer
    }

    public override var acceptsFirstResponder: Bool { true }
    public override var isOpaque: Bool { true }

    /// Shows `image`, or the empty canvas for nil. `keyToFrame` ends when the frame is on screen. The same
    /// photo's better frame (`sameZoom`) keeps the zoom and the spot, and so does any frame while sticky zoom
    /// is on; otherwise a photo opens at Fit. `zoomSizeFactor` and `isStandIn` are for a stand-in (see `sizeFactor`);
    /// focus peaking waits for the real frame.
    /// `keepView` is for the same photo at another resolution (the developed RAW over its preview, V-02): a zoomed-in
    /// view is rescaled so the same part of the picture stays under the same pixels of the screen.
    public func show(_ image: PreparedImage?, keyToFrame token: Perf.Token? = nil, sameZoom: Bool = false,
                     zoomSizeFactor: CGFloat = 1, keepView: Bool = false, isStandIn: Bool = false) {
        if let stale = pendingToken { Perf.end(stale) }
        pendingToken = token
        if keepView, let old = self.image, let image, case .scale(let s) = zoom {
            let oldWidth = zoomSize(of: old).width, newWidth = image.displaySize.width * zoomSizeFactor
            zoom = .scale(ZoomGeometry.scale(s, keepingSizeFrom: oldWidth, to: newWidth))
        }
        self.image = image
        self.isStandIn = isStandIn
        sizeFactor = zoomSizeFactor
        if image == nil { peakingMask = nil; clippingMask = nil }
        if clipping != nil { onClippingStats?(nil) }
        if !stickyZoom && !(sameZoom && image != nil) { resetZoom() }
        render()
    }

    /// Turns focus peaking on with `style`, off with nil, or changes its look. `token` (a `peaking` interval) ends when
    /// the result is presented. A change of color or sensitivity needs no new analysis; a change of mode does.
    public func setPeaking(_ style: PeakingStyle?, token: Perf.Token? = nil) {
        guard style != peaking else { if let token { Perf.end(token) }; return }
        peaking = style
        if style == nil { peakingMask = nil }
        if image != nil, window != nil {
            if let token {
                if let stale = pendingToken { Perf.end(stale) }
                pendingToken = token
            }
            render()
        } else if let token {
            Perf.end(token)
        }
    }

    /// Turns the clipping overlays on with `style`, off with nil, or changes them. `token` (a `clipping` interval) ends
    /// when the result is presented. Which marks are drawn, the stripes and the colors need no new analysis; a change
    /// of thresholds does.
    public func setClipping(_ style: ClippingStyle?, token: Perf.Token? = nil) {
        guard style != clipping else { if let token { Perf.end(token) }; return }
        clipping = style
        if style == nil || style?.marks.isEmpty == true { clippingMask = nil; onClippingStats?(nil) }
        if image != nil, window != nil {
            if let token {
                if let stale = pendingToken { Perf.end(stale) }
                pendingToken = token
            }
            render()
        } else if let token {
            Perf.end(token)
        }
    }

    /// The mask and parameters for this frame, encoding the analysis into `buffer` when the picture or thresholds changed.
    private func clippingPass(for image: PreparedImage, gpu: LoupeGPU, buffer: any MTLCommandBuffer) -> (mask: ClippingMask, params: ClipParams, gpu: ClippingGPU)? {
        guard let style = clipping, !style.marks.isEmpty, !isStandIn, let clippingGPU = gpu.clipping else { return nil }
        let mask: ClippingMask
        if let cached = clippingMask, cached.source === image.texture, cached.thresholds == style.thresholds {
            mask = cached
        } else if let made = clippingGPU.makeMask(for: image, thresholds: style.thresholds, reusing: clippingMask, in: buffer) {
            clippingMask = made
            mask = made
            buffer.addCompletedHandler { [weak self] _ in
                let stats = made.stats()
                DispatchQueue.main.async {
                    guard let self, self.clippingMask === made else { return }
                    self.onClippingStats?(stats)
                }
            }
        } else {
            return nil
        }
        let flags: UInt32 = (style.marks.contains(.highlights) ? 1 : 0) | (style.marks.contains(.shadows) ? 2 : 0) | (style.pattern ? 4 : 0)
        return (mask, ClipParams(highlightColor: ClippingGPU.highlightColor, shadowColor: ClippingGPU.shadowColor,
                                 levels: UInt32(mask.levels), flags: flags), clippingGPU)
    }

    /// The mask and parameters for this frame, encoding the analysis into `buffer` when the picture or mode changed.
    private func peakingPass(for image: PreparedImage, gpu: LoupeGPU, buffer: any MTLCommandBuffer) -> (mask: PeakingMask, params: PeakParams, gpu: PeakingGPU)? {
        guard let style = peaking, !isStandIn, let peakingGPU = gpu.peaking else { return nil }
        let threshold = PeakingThreshold.stored(sensitivity: style.sensitivity, mode: style.mode)
        let mask: PeakingMask
        if let cached = peakingMask, cached.source === image.texture, cached.mode == style.mode {
            peakingGPU.rebuildPyramid(of: cached, threshold: threshold, in: buffer)
            mask = cached
        } else if let made = peakingGPU.makeMask(for: image, mode: style.mode, threshold: threshold, reusing: peakingMask, in: buffer) {
            peakingMask = made
            mask = made
        } else {
            return nil
        }
        let params = PeakParams(color: SIMD4(style.color, 1),
                                threshold: threshold,
                                levels: UInt32(mask.levels))
        return (mask, params, peakingGPU)
    }

    /// Back to Fit, for a new folder.
    public func resetZoom() {
        zoom = .fit
        zoomCenter = CGPoint(x: 0.5, y: 0.5)
        returnScale = nil
        window?.invalidateCursorRects(for: self)
        render()
    }

    private func zoomSize(of image: PreparedImage) -> CGSize {
        CGSize(width: image.displaySize.width * sizeFactor, height: image.displaySize.height * sizeFactor)
    }

    /// Drawable pixels per image pixel on screen now.
    private func currentScale(image: PreparedImage, size: CGSize) -> CGFloat {
        let imageSize = zoomSize(of: image)
        switch zoom {
        case .fit: return ZoomGeometry.fitScale(imageSize: imageSize, viewSize: size)
        case .scale(let s): return s * oneToOneScale
        }
    }

    /// Switches to `level` at once, scaling the frame on screen. Zooming keeps the image point under the
    /// pointer there, or about the middle of the view when the pointer is not over the image. `token` (a `zoom`
    /// interval) ends when the result is presented.
    public func setZoom(_ level: ZoomLevel, token: Perf.Token? = nil) {
        if let image, window != nil, level != zoom {
            if let stale = pendingToken { Perf.end(stale) }
            pendingToken = token
            returnScale = nil
            change(to: level, image: image)
            render()
            onViewChange?(viewState)
        } else if let token {
            Perf.end(token)
        }
    }

    /// One stop of `=` or `−`.
    public func stepZoom(_ direction: ZoomDirection, token: Perf.Token? = nil) {
        guard let image, window != nil else { if let token { Perf.end(token) }; return }
        let size = drawableSize
        let fit = ZoomGeometry.fitScale(imageSize: zoomSize(of: image), viewSize: size) / oneToOneScale
        let current = currentScale(image: image, size: size) / oneToOneScale
        if let level = ZoomSteps.next(from: current, fit: fit, direction: direction) {
            setZoom(level, token: token)
        } else if let token {
            Perf.end(token)
        }
    }

    /// Z: Fit when zoomed, otherwise 1:1 (or the zoom Z last left, if that was not 1:1).
    public func toggleZoom(token: Perf.Token? = nil) {
        if case .scale(let s) = zoom {
            setZoom(.fit, token: token)
            if s != 1 { returnScale = s }
        } else {
            let back = returnScale
            setZoom(back.map(ZoomLevel.scale) ?? .actual, token: token)
        }
    }

    /// Changes the level, keeping the image point under the pointer. With the pointer off the image, a zoom from
    /// Fit goes to the camera's AF point (V-01); otherwise the middle of the view stays where it is.
    private func change(to level: ZoomLevel, image: PreparedImage) {
        let size = drawableSize
        let imageSize = zoomSize(of: image)
        let old = currentRect(image: image, size: size)
        func imagePoint(at point: CGPoint) -> CGPoint {
            old.width > 0 && old.height > 0
                ? CGPoint(x: (point.x - old.minX) / old.width, y: (point.y - old.minY) / old.height)
                : CGPoint(x: 0.5, y: 0.5)
        }
        let pointerSpot = pointerInPixels().flatMap { old.contains($0) ? ZoomAnchor.Spot(image: imagePoint(at: $0), view: $0) : nil }
        let middle = CGPoint(x: size.width / 2, y: size.height / 2)
        let spot = ZoomAnchor.resolve(pointer: pointerSpot, focus: focusAnchor, leavingFit: zoom == .fit, viewSize: size)
            ?? ZoomAnchor.Spot(image: imagePoint(at: middle), view: middle)
        zoom = level
        if level == .fit {
            zoomCenter = CGPoint(x: 0.5, y: 0.5)
        } else {
            zoomCenter = ZoomGeometry.center(keeping: spot.image, under: spot.view, imageSize: imageSize, viewSize: size,
                                             scale: currentScale(image: image, size: size))
        }
        window?.invalidateCursorRects(for: self)
    }

    /// A continuous zoom (pinch, `⌥`-scroll) by `factor` about the pointer. At or under Fit it is Fit.
    public func zoom(by factor: CGFloat) {
        guard let image, window != nil, factor > 0, factor.isFinite else { return }
        let size = drawableSize
        let one = oneToOneScale
        let fit = ZoomGeometry.fitScale(imageSize: zoomSize(of: image), viewSize: size)
        let target = min(max(currentScale(image: image, size: size) * factor, fit), max(ZoomSteps.maxScale * one, fit))
        let level: ZoomLevel = target <= fit * 1.0001 ? .fit : .scale(target / one)
        guard level != zoom else { return }
        returnScale = nil
        change(to: level, image: image)
        render()
        onViewChange?(viewState)
    }

    /// The zoom and the picture point at the middle of the view, as drawn: a center the edges clamped is reported
    /// where it really is.
    public var viewState: ViewState {
        guard let image, window != nil, case .scale(let s) = zoom else { return ViewState(level: zoom, center: zoomCenter) }
        let size = drawableSize
        let rect = ZoomGeometry.rect(imageSize: zoomSize(of: image), viewSize: size, scale: s * oneToOneScale, center: zoomCenter)
        return ViewState(level: zoom, center: ZoomGeometry.center(of: rect, viewSize: size))
    }

    /// Shows `state` (V-09), as a linked canvas follows the other one. The center is clamped by the edges when drawn.
    public func apply(_ state: ViewState) {
        guard state != viewState else { return }
        returnScale = nil
        zoom = state.level
        zoomCenter = state.level.isFit ? CGPoint(x: 0.5, y: 0.5) : state.center
        window?.invalidateCursorRects(for: self)
        render()
    }

    /// Moves the picture by `delta` points (the way the content moves), stopping at the image edges.
    public func pan(byPoints delta: CGPoint) {
        let scale = window?.backingScaleFactor ?? 1
        pan(byPixels: CGPoint(x: delta.x * scale, y: delta.y * scale))
    }

    private func pan(byPixels delta: CGPoint) {
        guard let image, window != nil, zoom != .fit else { return }
        let size = drawableSize
        zoomCenter = ZoomGeometry.panned(center: zoomCenter, by: delta, imageSize: zoomSize(of: image), viewSize: size,
                                         scale: currentScale(image: image, size: size))
        render()
        onViewChange?(viewState)
    }

    /// `⌥`-arrows: the view moves a quarter of its size over the photo, or a whole view with `page`.
    public func pan(_ direction: PanDirection, page: Bool = false) {
        let size = drawableSize
        let fraction: CGFloat = page ? 1 : 0.25
        // Looking left means the picture moves right.
        let (dx, dy): (CGFloat, CGFloat) = switch direction {
        case .left: (size.width * fraction, 0)
        case .right: (-size.width * fraction, 0)
        case .up: (0, size.height * fraction)
        case .down: (0, -size.height * fraction)
        }
        pan(byPixels: CGPoint(x: dx, y: dy))
    }

    /// Drawable pixels per image pixel at 1:1 on the display the window is on.
    private var oneToOneScale: CGFloat {
        guard let screen = window?.screen ?? NSScreen.main,
              let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID,
              let mode = CGDisplayCopyDisplayMode(number)
        else { return 1 }
        return ZoomGeometry.oneToOneScale(modePixelWidth: mode.pixelWidth, nativePixelWidth: Self.nativePixelWidth(of: number) ?? mode.pixelWidth)
    }

    /// The panel's own pixel width: the display's mode flagged native (`kDisplayModeNativeFlag`).
    private static func nativePixelWidth(of display: CGDirectDisplayID) -> Int? {
        let options = [kCGDisplayShowDuplicateLowResolutionModes: true] as CFDictionary
        let modes = CGDisplayCopyAllDisplayModes(display, options) as? [CGDisplayMode] ?? []
        return modes.first { $0.ioFlags & 0x0200_0000 != 0 }?.pixelWidth
    }

    private var drawableSize: CGSize {
        let scale = window?.backingScaleFactor ?? 1
        return CGSize(width: (bounds.width * scale).rounded(), height: (bounds.height * scale).rounded())
    }

    /// The pointer in drawable pixels, top-left origin; nil when it is outside the view.
    private func pointerInPixels() -> CGPoint? {
        guard let window else { return nil }
        let p = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        guard bounds.contains(p) else { return nil }
        let scale = window.backingScaleFactor
        return CGPoint(x: p.x * scale, y: (bounds.height - p.y) * scale)
    }

    private func currentRect(image: PreparedImage, size: CGSize) -> CGRect {
        let imageSize = zoomSize(of: image)
        return switch zoom {
        case .fit: FitGeometry.fitRect(imageSize: imageSize, viewSize: size)
        case .scale(let s):
            ZoomGeometry.rect(imageSize: imageSize, viewSize: size, scale: s * oneToOneScale, center: zoomCenter)
        }
    }

    private func publishZoom(rect: CGRect?) {
        var info: ZoomInfo?
        if let image, let rect, image.displaySize.width > 0, sizeFactor > 0 {
            let percent = Int((rect.width / zoomSize(of: image).width / oneToOneScale * 100).rounded())
            info = ZoomInfo(level: zoom, percent: percent)
        }
        guard info != lastInfo else { return }
        lastInfo = info
        onZoomChange?(info)
    }

    public override func layout() {
        super.layout()
        render()
    }

    /// Fullscreen transitions and window zooming resize the view without a live resize, and `layout()` can run
    /// before the final size is known; render at every size change so the last frame is never a stretched one.
    public override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        render()
    }

    public override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        render()
    }

    public override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        render()
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
        render()
    }

    // MARK: pointer and keys

    /// Two-finger scroll pans; with `⌥` it zooms about the pointer. A mouse wheel's notches are scaled up.
    public override func scrollWheel(with event: NSEvent) {
        let precise = event.hasPreciseScrollingDeltas
        let unit: CGFloat = precise ? 1 : 10
        if event.modifierFlags.contains(.option) {
            let dy = event.scrollingDeltaY * unit
            if dy != 0 { zoom(by: exp(dy * 0.01)) }
        } else {
            pan(byPoints: CGPoint(x: event.scrollingDeltaX * unit, y: event.scrollingDeltaY * unit))
        }
    }

    public override func magnify(with event: NSEvent) { zoom(by: 1 + event.magnification) }

    public override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        dragging = zoom != .fit
        if dragging { NSCursor.closedHand.push() }
    }

    public override func mouseDragged(with event: NSEvent) {
        guard dragging else { return }
        pan(byPoints: CGPoint(x: event.deltaX, y: event.deltaY))
    }

    public override func mouseUp(with event: NSEvent) { endDrag() }

    private func endDrag() {
        guard dragging else { return }
        dragging = false
        NSCursor.pop()
    }

    public override func resetCursorRects() {
        if zoom != .fit || spaceHeld { addCursorRect(bounds, cursor: .openHand) }
    }

    /// Holding Space shows the hand: Space and drag pans (a drag always does once zoomed in; Space says so).
    /// Every other key goes on to the responder chain as before.
    public override func keyDown(with event: NSEvent) {
        if event.keyCode == 49 { if !event.isARepeat { spaceHeld = true } } else { super.keyDown(with: event) }
    }

    public override func keyUp(with event: NSEvent) {
        if event.keyCode == 49 { spaceHeld = false } else { super.keyUp(with: event) }
    }

    public override func resignFirstResponder() -> Bool {
        spaceHeld = false
        endDrag()
        return super.resignFirstResponder()
    }

    // MARK: drawing

    private func render() {
        guard let gpu, window != nil else { return }
        let scale = window?.backingScaleFactor ?? 1
        let pixelSize = CGSize(width: (bounds.width * scale).rounded(), height: (bounds.height * scale).rounded())
        guard pixelSize.width >= 1, pixelSize.height >= 1 else { return }

        let layer = metalLayer
        layer.contentsScale = scale
        if layer.drawableSize != pixelSize { layer.drawableSize = pixelSize }
        layer.contentsGravity = .topLeft
        layer.colorspace = image?.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)
        // During a live resize the new frame must reach the screen in the same transaction as the layout.
        // The same goes for any resize (fullscreen, zoom): present with the layout, never a frame later.
        let resized = layer.drawableSize != lastDrawableSize
        lastDrawableSize = layer.drawableSize
        layer.presentsWithTransaction = inLiveResize || resized

        guard let drawable = layer.nextDrawable(), let buffer = gpu.queue.makeCommandBuffer() else { return }
        // The analysis is a compute pass, so it is encoded before the render pass and shares its command buffer:
        // turning peaking on costs no more than one frame.
        let peakingPass = image.flatMap { self.peakingPass(for: $0, gpu: gpu, buffer: buffer) }
        let clippingPass = image.flatMap { self.clippingPass(for: $0, gpu: gpu, buffer: buffer) }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColor(red: Self.canvasGray, green: Self.canvasGray,
                                                            blue: Self.canvasGray, alpha: 1)
        guard let encoder = buffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        if let image {
            let rect = currentRect(image: image, size: pixelSize)
            publishZoom(rect: rect)
            var quad = Quad(rect: rect, in: pixelSize, map: OrientationMap(image.orientation))
            encoder.setRenderPipelineState(gpu.pipeline)
            encoder.setVertexBytes(&quad, length: MemoryLayout<Quad>.stride, index: 0)
            encoder.setFragmentTexture(image.texture, index: 0)
            let crisp = zoom != .fit && rect.width >= image.displaySize.width
            encoder.setFragmentSamplerState(crisp ? gpu.nearestSampler : gpu.sampler, index: 0)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            if var pass = peakingPass {
                encoder.setRenderPipelineState(pass.gpu.overlay)
                encoder.setVertexBytes(&quad, length: MemoryLayout<Quad>.stride, index: 0)
                encoder.setFragmentTexture(pass.mask.texture, index: 0)
                encoder.setFragmentBytes(&pass.params, length: MemoryLayout<PeakParams>.stride, index: 0)
                encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            }
            if var pass = clippingPass {
                encoder.setRenderPipelineState(pass.gpu.overlay)
                encoder.setVertexBytes(&quad, length: MemoryLayout<Quad>.stride, index: 0)
                encoder.setFragmentTexture(pass.mask.texture, index: 0)
                encoder.setFragmentBytes(&pass.params, length: MemoryLayout<ClipParams>.stride, index: 0)
                encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            }
        }
        encoder.endEncoding()
        if image == nil { publishZoom(rect: nil) }

        if let token = pendingToken {
            pendingToken = nil
            // Presented handlers run off the main thread; the token is a value and Perf.end is thread-safe.
            drawable.addPresentedHandler { _ in Perf.end(token) }
        }
        if layer.presentsWithTransaction {
            buffer.commit()
            buffer.waitUntilScheduled()
            drawable.present()
        } else {
            buffer.present(drawable)
            buffer.commit()
        }
    }
}

/// Must match `Quad` in the shader: the image's rect in clip space and where each corner reads from.
struct Quad {
    var rect: SIMD4<Float>
    var uv0: SIMD2<Float>
    var uv1: SIMD2<Float>
    var uv2: SIMD2<Float>
    var uv3: SIMD2<Float>

    /// `rect` is in pixels with a top-left origin; `size` is the drawable's size in pixels.
    init(rect: CGRect, in size: CGSize, map: OrientationMap) {
        func clipX(_ x: CGFloat) -> Float { Float(x / size.width * 2 - 1) }
        func clipY(_ y: CGFloat) -> Float { Float(1 - y / size.height * 2) }
        self.rect = SIMD4(clipX(rect.minX), clipY(rect.minY), clipX(rect.maxX), clipY(rect.maxY))
        func uv(_ p: CGPoint) -> SIMD2<Float> { SIMD2(Float(p.x), Float(p.y)) }
        (uv0, uv1, uv2, uv3) = (uv(map.topLeft), uv(map.topRight), uv(map.bottomLeft), uv(map.bottomRight))
    }
}
