import CoreGraphics
import CoreImage
import Diagnostics
import ImageIO
import Metal

/// An image ready to draw: pixels on the GPU (with mipmaps), the orientation still to apply, and the color
/// space the layer must be tagged with so the system matches it to the display.
public struct PreparedImage: @unchecked Sendable {
    let texture: any MTLTexture
    public let orientation: CGImagePropertyOrientation
    public let colorSpace: CGColorSpace
    /// Upright size in pixels (width and height swapped for rotated orientations).
    public let displaySize: CGSize
    /// Memory the texture holds, mip chain included (a third more than level 0). What the frame cache counts.
    public let byteCost: Int
}

/// The Metal device, queue and pipeline, shared by every Loupe view and usable from any thread.
/// Textures are prepared off the main thread so a big upload never stalls the UI.
public final class LoupeGPU: @unchecked Sendable {
    public static let shared: LoupeGPU? = LoupeGPU()

    static let pixelFormat = MTLPixelFormat.bgra8Unorm

    let device: any MTLDevice
    let queue: any MTLCommandQueue
    let pipeline: any MTLRenderPipelineState
    let sampler: any MTLSamplerState
    /// For 1:1 and beyond: shows the actual pixels, never blended (M-14 open question 1).
    let nearestSampler: any MTLSamplerState
    /// Renders developed RAWs (V-02) on the same queue, in extended linear Display P3 so nothing clips on the way.
    private let ciContext: CIContext
    /// Focus peaking (V-06); nil only if its shaders failed to build, in which case the overlay is simply absent.
    let peaking: PeakingGPU?
    /// Highlight and shadow clipping (V-07); nil only if its shaders failed to build.
    let clipping: ClippingGPU?

    private init?() {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue(),
              let library = try? device.makeLibrary(source: Self.shaderSource, options: nil),
              let vertex = library.makeFunction(name: "loupeVertex"),
              let fragment = library.makeFunction(name: "loupeFragment")
        else { return nil }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertex
        descriptor.fragmentFunction = fragment
        descriptor.colorAttachments[0].pixelFormat = Self.pixelFormat
        guard let pipeline = try? device.makeRenderPipelineState(descriptor: descriptor) else { return nil }
        let samplerDescriptor = MTLSamplerDescriptor()
        samplerDescriptor.minFilter = .linear
        samplerDescriptor.magFilter = .linear
        samplerDescriptor.mipFilter = .linear
        samplerDescriptor.maxAnisotropy = 16
        samplerDescriptor.sAddressMode = .clampToEdge
        samplerDescriptor.tAddressMode = .clampToEdge
        guard let sampler = device.makeSamplerState(descriptor: samplerDescriptor) else { return nil }
        let nearest = MTLSamplerDescriptor()
        nearest.minFilter = .nearest
        nearest.magFilter = .nearest
        nearest.mipFilter = .notMipmapped
        nearest.sAddressMode = .clampToEdge
        nearest.tAddressMode = .clampToEdge
        guard let nearestSampler = device.makeSamplerState(descriptor: nearest) else { return nil }
        (self.device, self.queue, self.pipeline, self.sampler, self.nearestSampler) = (device, queue, pipeline, sampler, nearestSampler)
        peaking = PeakingGPU(device: device, vertex: vertex, pixelFormat: Self.pixelFormat)
        clipping = ClippingGPU(device: device, vertex: vertex, pixelFormat: Self.pixelFormat)
        ciContext = CIContext(mtlCommandQueue: queue, options: [
            .workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3) as Any,
            .cacheIntermediates: false,
        ])
    }

    /// Uploads `image` with a full mip chain. The pixels are drawn into a BGRA context in the image's own color
    /// space, so their values are untouched and the layer's color space is what gives them meaning.
    /// Returns nil when the image is empty or larger than the GPU allows.
    public func prepare(_ image: CGImage, orientation: CGImagePropertyOrientation) -> PreparedImage? {
        let width = image.width, height = image.height
        guard width > 0, height > 0, width <= 16384, height <= 16384 else { return nil }
        let token = Perf.begin(.textureUpload)
        defer { Perf.end(token) }

        var colorSpace = image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        if colorSpace.model != .rgb { colorSpace = CGColorSpace(name: CGColorSpace.sRGB)! }

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: Self.pixelFormat, width: width,
                                                                  height: height, mipmapped: true)
        descriptor.usage = .shaderRead
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }

        // Core Graphics draws straight into a shared buffer (unified memory, no staging copy on the CPU); the GPU
        // then copies it into the mipmapped texture and builds the chain.
        let bytesPerRow = width * 4
        guard let staging = device.makeBuffer(length: bytesPerRow * height, options: .storageModeShared) else { return nil }
        let bitmapInfo = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
        guard let context = CGContext(data: staging.contents(), width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: bytesPerRow, space: colorSpace, bitmapInfo: bitmapInfo)
        else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        guard let buffer = queue.makeCommandBuffer(), let blit = buffer.makeBlitCommandEncoder() else { return nil }
        blit.copy(from: staging, sourceOffset: 0, sourceBytesPerRow: bytesPerRow, sourceBytesPerImage: bytesPerRow * height,
                  sourceSize: MTLSize(width: width, height: height, depth: 1), to: texture, destinationSlice: 0,
                  destinationLevel: 0, destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
        blit.generateMipmaps(for: texture)
        blit.endEncoding()
        buffer.commit()
        buffer.waitUntilCompleted()

        let size = orientation.swapsAxes ? CGSize(width: height, height: width) : CGSize(width: width, height: height)
        return PreparedImage(texture: texture, orientation: orientation, colorSpace: colorSpace, displaySize: size,
                             byteCost: width * height * 4 * 4 / 3)
    }

    /// Renders `image` (upright, extent from the origin) straight into a mipmapped texture at its own pixel size,
    /// encoded as Display P3. Every texel is one pixel of `image`: nothing is resampled, which is what 1:1 needs.
    /// Throws `CancellationError` when the task was cancelled before the render started, and nil when the image is
    /// empty or larger than the GPU allows.
    public func prepare(developed image: CIImage) throws -> PreparedImage? {
        let extent = image.extent.integral
        let width = Int(extent.width), height = Int(extent.height)
        guard width > 0, height > 0, width <= 16384, height <= 16384 else { return nil }
        let token = Perf.begin(.textureUpload)
        defer { Perf.end(token) }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: Self.pixelFormat, width: width,
                                                                  height: height, mipmapped: true)
        descriptor.usage = [.shaderRead, .shaderWrite, .renderTarget]
        descriptor.storageMode = .private
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        let space = CGColorSpace(name: CGColorSpace.displayP3)!
        let destination = CIRenderDestination(mtlTexture: texture, commandBuffer: nil)
        destination.colorSpace = space
        // Core Image's origin is bottom left, a texture's top left.
        destination.isFlipped = true
        try Task.checkCancellation()
        do {
            _ = try ciContext.startTask(toRender: image, from: extent, to: destination, at: .zero).waitUntilCompleted()
        } catch {
            return nil
        }
        try Task.checkCancellation()
        guard let buffer = queue.makeCommandBuffer(), let blit = buffer.makeBlitCommandEncoder() else { return nil }
        blit.generateMipmaps(for: texture)
        blit.endEncoding()
        buffer.commit()
        buffer.waitUntilCompleted()
        return PreparedImage(texture: texture, orientation: .up, colorSpace: space,
                             displaySize: CGSize(width: width, height: height), byteCost: width * height * 4 * 4 / 3)
    }

    /// The pixels of `image` at the smallest mip level whose long edge is at most `maxEdge` (level 0 when it is
    /// smaller already), as tightly packed B, G, R, A bytes. For the histogram of a frame that was rendered on the
    /// GPU and never exists as a `CGImage`.
    public func readback(_ image: PreparedImage, maxEdge: Int) -> (bgra: [UInt8], width: Int, height: Int)? {
        let texture = image.texture
        var level = 0
        while max(texture.width >> level, texture.height >> level) > maxEdge, level + 1 < texture.mipmapLevelCount { level += 1 }
        let w = max(1, texture.width >> level), h = max(1, texture.height >> level)
        let bytesPerRow = w * 4
        guard let staging = device.makeBuffer(length: bytesPerRow * h, options: .storageModeShared),
              let buffer = queue.makeCommandBuffer(), let blit = buffer.makeBlitCommandEncoder() else { return nil }
        blit.copy(from: texture, sourceSlice: 0, sourceLevel: level, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                  sourceSize: MTLSize(width: w, height: h, depth: 1), to: staging, destinationOffset: 0,
                  destinationBytesPerRow: bytesPerRow, destinationBytesPerImage: bytesPerRow * h)
        blit.endEncoding()
        buffer.commit()
        buffer.waitUntilCompleted()
        let bytes = Array(UnsafeBufferPointer(start: staging.contents().assumingMemoryBound(to: UInt8.self), count: bytesPerRow * h))
        return (bytes, w, h)
    }

    // One quad as a triangle strip (top-left, top-right, bottom-left, bottom-right). The CPU gives the rect in
    // clip space and where each corner reads from in the stored image, which is how orientation is applied.
    static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct Quad {
        float4 rect;   // left, top, right, bottom in clip space
        float2 uv[4];  // stored-image coordinates for TL, TR, BL, BR
    };
    struct VertexOut {
        float4 position [[position]];
        float2 uv;
    };

    vertex VertexOut loupeVertex(uint vid [[vertex_id]], constant Quad &q [[buffer(0)]]) {
        float x = (vid & 1) ? q.rect.z : q.rect.x;
        float y = (vid & 2) ? q.rect.w : q.rect.y;
        VertexOut out;
        out.position = float4(x, y, 0, 1);
        out.uv = q.uv[vid];
        return out;
    }

    fragment float4 loupeFragment(VertexOut in [[stage_in]], texture2d<float> image [[texture(0)]],
                                  sampler s [[sampler(0)]]) {
        float4 c = image.sample(s, in.uv);
        return float4(c.rgb, 1.0);
    }
    """
}
