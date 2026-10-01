import AppKit
import Diagnostics
import Metal
import QuartzCore

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

    /// Fit or 1:1, and the image point (0...1) at the middle of the view while zoomed in.
    public private(set) var zoom = ZoomMode.fit
    private var zoomCenter = CGPoint(x: 0.5, y: 0.5)
    private var lastInfo: ZoomInfo?
    /// Called when the zoom level the info strip shows changes.
    public var onZoomChange: ((ZoomInfo?) -> Void)?

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

    /// Shows `image`, or the empty canvas for nil. `keyToFrame` ends when the frame is on screen. A different
    /// photo opens at Fit; the same photo's better frame (`sameZoom`) keeps the zoom and the spot.
    public func show(_ image: PreparedImage?, keyToFrame token: Perf.Token? = nil, sameZoom: Bool = false) {
        if let stale = pendingToken { Perf.end(stale) }
        pendingToken = token
        self.image = image
        if !sameZoom || image == nil { resetZoom() }
        render()
    }

    private func resetZoom() {
        zoom = .fit
        zoomCenter = CGPoint(x: 0.5, y: 0.5)
    }

    /// Switches to `mode` at once, scaling the frame on screen. Zooming in keeps the image point under the
    /// pointer there, or zooms about the middle when the pointer is not over the image. `token` (a `zoom`
    /// interval) ends when the result is presented.
    public func setZoom(_ mode: ZoomMode, token: Perf.Token? = nil) {
        guard let image, window != nil, mode != zoom else {
            if let token { Perf.end(token) }
            return
        }
        if let stale = pendingToken { Perf.end(stale) }
        pendingToken = token
        let size = drawableSize
        if mode == .actual {
            let imageSize = image.displaySize
            let old = currentRect(image: image, size: size)
            var anchor: CGPoint?
            if let p = pointerInPixels(), old.contains(p) { anchor = p }
            let u = anchor.map { CGPoint(x: ($0.x - old.minX) / old.width, y: ($0.y - old.minY) / old.height) }
                ?? CGPoint(x: 0.5, y: 0.5)
            let scale = oneToOneScale
            let point = anchor ?? CGPoint(x: size.width / 2, y: size.height / 2)
            zoomCenter = ZoomGeometry.center(keeping: u, under: point, imageSize: imageSize, viewSize: size, scale: scale)
        } else {
            zoomCenter = CGPoint(x: 0.5, y: 0.5)
        }
        zoom = mode
        render()
    }

    public func toggleZoom(token: Perf.Token? = nil) { setZoom(zoom == .fit ? .actual : .fit, token: token) }

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
        switch zoom {
        case .fit: FitGeometry.fitRect(imageSize: image.displaySize, viewSize: size)
        case .actual:
            ZoomGeometry.rect(imageSize: image.displaySize, viewSize: size, scale: oneToOneScale, center: zoomCenter)
        }
    }

    private func publishZoom(rect: CGRect?) {
        var info: ZoomInfo?
        if let image, let rect, image.displaySize.width > 0 {
            let percent = Int((rect.width / image.displaySize.width / oneToOneScale * 100).rounded())
            info = ZoomInfo(mode: zoom, percent: percent)
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
            let crisp = zoom == .actual && rect.width >= image.displaySize.width
            encoder.setFragmentSamplerState(crisp ? gpu.nearestSampler : gpu.sampler, index: 0)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
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
