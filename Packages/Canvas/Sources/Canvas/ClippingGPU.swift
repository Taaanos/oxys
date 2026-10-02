import CoreGraphics
import Metal

/// The clipping map of one picture (V-07), in the stored (not rotated) image space.
///
/// Two channels: red is 1 where the pixel is a highlight, green 1 where it is a shadow. Level 0 is every source
/// pixel; each level above holds the largest value under its texel, so a screen pixel that covers many source pixels
/// is marked when any of them is clipped. (Unlike focus peaking, one clipped pixel is exactly what the photographer
/// wants to see, so there is no count.)
final class ClippingMask: @unchecked Sendable {
    let texture: any MTLTexture
    let levelViews: [any MTLTexture]
    /// What it was made from. Held, so a new picture can never be taken for this one when memory is reused.
    let source: any MTLTexture
    let thresholds: ClippingThresholds
    /// The counts, filled by the GPU. Read after the command buffer completed.
    let counts: any MTLBuffer

    var levels: Int { texture.mipmapLevelCount }
    var width: Int { texture.width }
    var height: Int { texture.height }

    init(texture: any MTLTexture, levelViews: [any MTLTexture], source: any MTLTexture, thresholds: ClippingThresholds, counts: any MTLBuffer) {
        self.texture = texture
        self.levelViews = levelViews
        self.source = source
        self.thresholds = thresholds
        self.counts = counts
    }

    /// The counts after the buffer that made this mask has completed.
    func stats() -> ClippingStats {
        let values = counts.contents().assumingMemoryBound(to: UInt32.self)
        return ClippingStats(highlightPixels: Int(values[0]), shadowPixels: Int(values[1]), totalPixels: width * height)
    }
}

/// Parameters of the overlay pass; must match `ClipParams` in the shader.
struct ClipParams {
    var highlightColor: SIMD4<Float>
    var shadowColor: SIMD4<Float>
    var levels: UInt32
    /// Bit 0: draw highlights. Bit 1: draw shadows. Bit 2: stripes instead of solid.
    var flags: UInt32
}

/// The compute and render pipelines for the clipping overlays.
///
/// Pass 1 (compute) reads the picture, writes the two-channel map and counts the clipped pixels (per SIMD group, then
/// per threadgroup, then one atomic add per threadgroup). Pass 2 (compute, one dispatch per level) takes the maximum
/// of 2 x 2 texels. Pass 3 (the overlay) runs with the picture's quad. The map does not depend on which of `H` and `S`
/// is on, so switching either needs only the overlay draw.
final class ClippingGPU: @unchecked Sendable {
    static let maxLevels = 8

    /// Red for highlights and blue for shadows, in the picture's color space. Not on the screen as exact values: the
    /// stripes carry the difference too.
    static let highlightColor = SIMD4<Float>(1, 0.1, 0.1, 1)
    static let shadowColor = SIMD4<Float>(0.15, 0.4, 1, 1)

    let device: any MTLDevice
    private let classify: any MTLComputePipelineState
    private let reduce: any MTLComputePipelineState
    let overlay: any MTLRenderPipelineState

    init?(device: any MTLDevice, vertex: any MTLFunction, pixelFormat: MTLPixelFormat) {
        guard let library = try? device.makeLibrary(source: Self.shaderSource, options: nil),
              let classifyFunction = library.makeFunction(name: "clipClassify"),
              let reduceFunction = library.makeFunction(name: "clipReduce"),
              let fragment = library.makeFunction(name: "clippingFragment"),
              let classify = try? device.makeComputePipelineState(function: classifyFunction),
              let reduce = try? device.makeComputePipelineState(function: reduceFunction)
        else { return nil }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertex
        descriptor.fragmentFunction = fragment
        descriptor.colorAttachments[0].pixelFormat = pixelFormat
        guard let overlay = try? device.makeRenderPipelineState(descriptor: descriptor) else { return nil }
        (self.device, self.classify, self.reduce, self.overlay) = (device, classify, reduce, overlay)
    }

    /// A mask for `image`, made in `buffer` before whatever the buffer draws. `previous` donates its texture when the
    /// size matches (a burst). Nil when a texture could not be made.
    func makeMask(for image: PreparedImage, thresholds: ClippingThresholds, reusing previous: ClippingMask?, in buffer: any MTLCommandBuffer) -> ClippingMask? {
        let source = image.texture
        let width = source.width, height = source.height
        var levels = 1, edge = max(width, height)
        while edge > 1, levels < Self.maxLevels { edge >>= 1; levels += 1 }
        let texture: any MTLTexture
        let views: [any MTLTexture]
        if let previous, previous.width == width, previous.height == height, previous.levels == levels {
            (texture, views) = (previous.texture, previous.levelViews)
        } else {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rg8Unorm, width: width, height: height, mipmapped: levels > 1)
            descriptor.mipmapLevelCount = levels
            descriptor.usage = [.shaderRead, .shaderWrite, .pixelFormatView]
            descriptor.storageMode = .private
            guard let made = device.makeTexture(descriptor: descriptor) else { return nil }
            var list: [any MTLTexture] = []
            for level in 0..<levels {
                guard let view = made.makeTextureView(pixelFormat: .rg8Unorm, textureType: .type2D, levels: level..<(level + 1), slices: 0..<1) else { return nil }
                list.append(view)
            }
            (texture, views) = (made, list)
        }
        // A buffer of its own per mask: the previous picture's counts may still be read on another thread.
        guard let counts = device.makeBuffer(length: 8, options: .storageModeShared), let blit = buffer.makeBlitCommandEncoder() else { return nil }
        blit.fill(buffer: counts, range: 0..<8, value: 0)
        blit.endEncoding()
        let mask = ClippingMask(texture: texture, levelViews: views, source: source, thresholds: thresholds, counts: counts)

        guard let encoder = buffer.makeComputeCommandEncoder() else { return nil }
        encoder.label = "Clipping mask"
        encoder.setComputePipelineState(classify)
        encoder.setTexture(source, index: 0)
        encoder.setTexture(views[0], index: 1)
        // Half a level below the cut, so an 8-bit value and a 16-bit float both land on the same side.
        var cuts = SIMD2<Float>((Float(thresholds.highlightByte) - 0.5) / 255, (Float(thresholds.shadowByte) + 0.5) / 255)
        encoder.setBytes(&cuts, length: MemoryLayout<SIMD2<Float>>.size, index: 0)
        encoder.setBuffer(counts, offset: 0, index: 1)
        encoder.dispatchThreadgroups(MTLSize(width: (width + 15) / 16, height: (height + 15) / 16, depth: 1),
                                     threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
        encoder.setComputePipelineState(reduce)
        for level in 1..<max(levels, 1) {
            encoder.memoryBarrier(scope: .textures)
            encoder.setTexture(views[level - 1], index: 0)
            encoder.setTexture(views[level], index: 1)
            encoder.dispatchThreads(MTLSize(width: max(1, width >> level), height: max(1, height >> level), depth: 1),
                                    threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
        }
        encoder.endEncoding()
        return mask
    }

    static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    // Highlight: any channel at or above the cut. Shadow: all channels at or below it. cuts.x is half a level below
    // the first highlight value, cuts.y half a level above the last shadow value.
    kernel void clipClassify(texture2d<float, access::read> img [[texture(0)]],
                             texture2d<float, access::write> out [[texture(1)]],
                             constant float2 &cuts [[buffer(0)]],
                             device atomic_uint *counts [[buffer(1)]],
                             uint2 gid [[thread_position_in_grid]],
                             uint lane [[thread_index_in_simdgroup]],
                             uint tid [[thread_index_in_threadgroup]]) {
        threadgroup atomic_uint groupCounts[2];
        if (tid == 0) { atomic_store_explicit(&groupCounts[0], 0, memory_order_relaxed); atomic_store_explicit(&groupCounts[1], 0, memory_order_relaxed); }
        threadgroup_barrier(mem_flags::mem_threadgroup);
        uint hi = 0, lo = 0;
        if (gid.x < out.get_width() && gid.y < out.get_height()) {
            float3 c = img.read(gid).rgb;
            hi = any(c >= cuts.x) ? 1 : 0;
            lo = all(c <= cuts.y) ? 1 : 0;
            out.write(float4(float(hi), float(lo), 0, 0), gid);
        }
        uint hiSum = simd_sum(hi), loSum = simd_sum(lo);
        if (lane == 0) {
            atomic_fetch_add_explicit(&groupCounts[0], hiSum, memory_order_relaxed);
            atomic_fetch_add_explicit(&groupCounts[1], loSum, memory_order_relaxed);
        }
        threadgroup_barrier(mem_flags::mem_threadgroup);
        if (tid == 0) {
            atomic_fetch_add_explicit(&counts[0], atomic_load_explicit(&groupCounts[0], memory_order_relaxed), memory_order_relaxed);
            atomic_fetch_add_explicit(&counts[1], atomic_load_explicit(&groupCounts[1], memory_order_relaxed), memory_order_relaxed);
        }
    }

    // The largest of up to 3 x 3 texels below (3 at an odd edge, so none is dropped).
    kernel void clipReduce(texture2d<float, access::read> src [[texture(0)]],
                           texture2d<float, access::write> dst [[texture(1)]],
                           uint2 gid [[thread_position_in_grid]]) {
        uint dw = dst.get_width(), dh = dst.get_height();
        if (gid.x >= dw || gid.y >= dh) return;
        uint sw = src.get_width(), sh = src.get_height();
        uint x0 = min(gid.x * 2, sw - 1), y0 = min(gid.y * 2, sh - 1);
        uint x1 = gid.x == dw - 1 ? sw - 1 : min(x0 + 1, sw - 1);
        uint y1 = gid.y == dh - 1 ? sh - 1 : min(y0 + 1, sh - 1);
        float2 best = float2(0);
        for (uint y = y0; y <= y1; y++) {
            for (uint x = x0; x <= x1; x++) best = max(best, src.read(uint2(x, y)).rg);
        }
        dst.write(float4(best, 0, 0), gid);
    }

    struct VertexOut {
        float4 position [[position]];
        float2 uv;
    };
    struct ClipParams {
        float4 highlightColor;
        float4 shadowColor;
        uint levels;
        uint flags;
    };

    // Paints where the picture is clipped under this screen pixel: the level that matches the footprint, at 9 points
    // across it when zoomed out. Solid, or stripes: highlights slant one way, shadows the other, 6 px period.
    fragment float4 clippingFragment(VertexOut in [[stage_in]], texture2d<float, access::read> mask [[texture(0)]],
                                     constant ClipParams &p [[buffer(0)]]) {
        float2 base = float2(mask.get_width(), mask.get_height());
        float2 ext = (abs(dfdx(in.uv)) + abs(dfdy(in.uv))) * base;
        float footprint = max(ext.x, ext.y);
        uint lod = 0;
        float reach = 0;
        int taps = 0;
        if (footprint > 1.0001) {
            lod = min(uint(floor(log2(footprint))), p.levels - 1);
            reach = 0.5 * footprint * 0.99;
            taps = 1;
        }
        float2 size = float2(mask.get_width(lod), mask.get_height(lod));
        float scale = float(1u << lod);
        float2 found = float2(0);
        for (int dy = -taps; dy <= taps; dy++) {
            for (int dx = -taps; dx <= taps; dx++) {
                float2 texel = in.uv * base + float2(dx, dy) * reach;
                uint2 q = uint2(clamp(floor(texel / scale), float2(0), size - 1));
                found = max(found, mask.read(q, lod).rg);
            }
        }
        bool hi = (p.flags & 1u) != 0 && found.x > 0.5;
        bool lo = (p.flags & 2u) != 0 && found.y > 0.5;
        if (!hi && !lo) discard_fragment();
        bool stripes = (p.flags & 4u) != 0;
        float2 px = in.position.xy;
        // Both at once is possible when zoomed out: highlights win the tie.
        bool useHighlight = hi;
        if (stripes) {
            float phase = useHighlight ? px.x + px.y : px.x - px.y;
            if (fmod(phase + 1024.0, 6.0) >= 3.0) discard_fragment();
        }
        return useHighlight ? float4(p.highlightColor.rgb, 1.0) : float4(p.shadowColor.rgb, 1.0);
    }
    """
}

extension LoupeGPU {
    /// The clipped counts of `image` for `thresholds`, from the same compute pass as the overlay. What the tests check
    /// against an independent count, and what a later tool can use to rank frames.
    public func clippingStats(of image: PreparedImage, thresholds: ClippingThresholds) -> ClippingStats? {
        guard let clipping, let buffer = queue.makeCommandBuffer(),
              let mask = clipping.makeMask(for: image, thresholds: thresholds, reusing: nil, in: buffer) else { return nil }
        buffer.commit()
        buffer.waitUntilCompleted()
        return mask.stats()
    }
}
