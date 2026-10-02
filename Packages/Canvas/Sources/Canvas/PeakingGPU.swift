import CoreGraphics
import Metal

/// The edge-strength map of one picture (V-06), in the stored (not rotated) image space.
///
/// Level 0 holds the strength of every source pixel (one byte, the square root of a luma step). Every level above
/// it holds how many source pixels under that texel passed the threshold (a count, up to 255), so a screen pixel
/// that covers many source pixels can ask "are enough of them sharp?" instead of "is any one of them?". The second
/// question marks every noisy photo from edge to edge.
final class PeakingMask: @unchecked Sendable {
    let texture: any MTLTexture
    /// One view per level, for writing the pyramid.
    let levelViews: [any MTLTexture]
    /// What it was made from. Held, so a new picture can never be taken for this one when memory is reused.
    let source: any MTLTexture
    let mode: PeakingMode
    /// The stored threshold the counts above level 0 were made with.
    var pyramidThreshold: Float

    var width: Int { texture.width }
    var height: Int { texture.height }
    var levels: Int { texture.mipmapLevelCount }

    init(texture: any MTLTexture, levelViews: [any MTLTexture], source: any MTLTexture, mode: PeakingMode, pyramidThreshold: Float) {
        self.texture = texture
        self.levelViews = levelViews
        self.source = source
        self.mode = mode
        self.pyramidThreshold = pyramidThreshold
    }
}

/// Parameters of the overlay pass; must match `PeakParams` in the shader.
struct PeakParams {
    var color: SIMD4<Float>
    var threshold: Float
    var levels: UInt32
}

/// The compute and render pipelines for focus peaking.
///
/// Pass 1 (compute) reads the picture's pixels, takes luma, and writes the edge strength of every pixel (Sobel on
/// lightly smoothed luma for Edges, Laplacian for Fine detail). Pass 2 (compute, one dispatch per level) counts, per
/// block of source pixels, how many passed the threshold. Pass 3 (the overlay) runs with the picture's quad: zoomed in
/// it paints the pixels whose strength passes the threshold; zoomed out it reads the level that matches how many
/// source pixels one screen pixel covers and paints where enough of them passed. The counts depend on the threshold,
/// so a change of sensitivity runs pass 2 again (a fraction of a millisecond), not pass 1.
final class PeakingGPU: @unchecked Sendable {
    /// The mask has at most this many levels; 8 covers a screen pixel standing for 128 source pixels across.
    static let maxLevels = 8

    let device: any MTLDevice
    private let edges: any MTLComputePipelineState
    private let fine: any MTLComputePipelineState
    private let countFirst: any MTLComputePipelineState
    private let countNext: any MTLComputePipelineState
    let overlay: any MTLRenderPipelineState

    init?(device: any MTLDevice, vertex: any MTLFunction, pixelFormat: MTLPixelFormat) {
        guard let library = try? device.makeLibrary(source: Self.shaderSource, options: nil),
              let edgesFunction = library.makeFunction(name: "peakEdges"),
              let fineFunction = library.makeFunction(name: "peakFine"),
              let countFirstFunction = library.makeFunction(name: "peakCountFirst"),
              let countNextFunction = library.makeFunction(name: "peakCountNext"),
              let fragment = library.makeFunction(name: "peakingFragment"),
              let edges = try? device.makeComputePipelineState(function: edgesFunction),
              let fine = try? device.makeComputePipelineState(function: fineFunction),
              let countFirst = try? device.makeComputePipelineState(function: countFirstFunction),
              let countNext = try? device.makeComputePipelineState(function: countNextFunction)
        else { return nil }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertex
        descriptor.fragmentFunction = fragment
        descriptor.colorAttachments[0].pixelFormat = pixelFormat
        guard let overlay = try? device.makeRenderPipelineState(descriptor: descriptor) else { return nil }
        (self.device, self.edges, self.fine, self.countFirst, self.countNext, self.overlay) = (device, edges, fine, countFirst, countNext, overlay)
    }

    /// Levels for a picture of this size: down to 1x1, at most ``maxLevels``.
    static func levelCount(width: Int, height: Int) -> Int {
        var levels = 1, edge = max(width, height)
        while edge > 1, levels < maxLevels { edge >>= 1; levels += 1 }
        return levels
    }

    /// A mask for `image`, made in `buffer` before whatever the buffer draws. `previous` donates its texture when the
    /// size matches, which it does through a burst. Nil when the texture could not be made.
    func makeMask(for image: PreparedImage, mode: PeakingMode, threshold: Float, reusing previous: PeakingMask?, in buffer: any MTLCommandBuffer) -> PeakingMask? {
        let source = image.texture
        let width = source.width, height = source.height
        let levels = Self.levelCount(width: width, height: height)
        let mask: PeakingMask
        if let previous, previous.width == width, previous.height == height, previous.levels == levels {
            mask = PeakingMask(texture: previous.texture, levelViews: previous.levelViews, source: source, mode: mode, pyramidThreshold: threshold)
        } else {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r8Unorm, width: width, height: height, mipmapped: levels > 1)
            descriptor.mipmapLevelCount = levels
            descriptor.usage = [.shaderRead, .shaderWrite, .pixelFormatView]
            descriptor.storageMode = .private
            guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
            var views: [any MTLTexture] = []
            for level in 0..<levels {
                guard let view = texture.makeTextureView(pixelFormat: .r8Unorm, textureType: .type2D,
                                                         levels: level..<(level + 1), slices: 0..<1) else { return nil }
                views.append(view)
            }
            mask = PeakingMask(texture: texture, levelViews: views, source: source, mode: mode, pyramidThreshold: threshold)
        }
        guard let encoder = buffer.makeComputeCommandEncoder() else { return nil }
        encoder.label = "Focus peaking mask"
        encoder.setComputePipelineState(mode == .edges ? edges : fine)
        encoder.setTexture(source, index: 0)
        encoder.setTexture(mask.levelViews[0], index: 1)
        // Whole 16 x 16 groups, the last ones overhanging the picture: the kernels share a tile of luma per group.
        encoder.dispatchThreadgroups(MTLSize(width: (width + 15) / 16, height: (height + 15) / 16, depth: 1),
                                     threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
        encodePyramid(of: mask, threshold: threshold, in: encoder)
        encoder.endEncoding()
        return mask
    }

    /// The counts above level 0 again, for a new threshold. Level 0 stays as it is.
    func rebuildPyramid(of mask: PeakingMask, threshold: Float, in buffer: any MTLCommandBuffer) {
        guard mask.levels > 1, threshold != mask.pyramidThreshold, let encoder = buffer.makeComputeCommandEncoder() else { return }
        encoder.label = "Focus peaking counts"
        encodePyramid(of: mask, threshold: threshold, in: encoder)
        encoder.endEncoding()
        mask.pyramidThreshold = threshold
    }

    private func encodePyramid(of mask: PeakingMask, threshold: Float, in encoder: any MTLComputeCommandEncoder) {
        var threshold = threshold
        for level in 1..<max(mask.levels, 1) {
            encoder.memoryBarrier(scope: .textures)
            encoder.setComputePipelineState(level == 1 ? countFirst : countNext)
            encoder.setTexture(mask.levelViews[level - 1], index: 0)
            encoder.setTexture(mask.levelViews[level], index: 1)
            encoder.setBytes(&threshold, length: MemoryLayout<Float>.size, index: 0)
            dispatch(encoder, width: max(1, mask.width >> level), height: max(1, mask.height >> level))
        }
    }

    private func dispatch(_ encoder: any MTLComputeCommandEncoder, width: Int, height: Int) {
        encoder.dispatchThreads(MTLSize(width: width, height: height, depth: 1),
                                threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
    }

    static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    // Luma of the encoded values, with the same Rec. 709 weights as the histogram. Edges of the picture repeat.
    static float lumaAt(texture2d<float, access::read> img, int2 p) {
        int2 size = int2(img.get_width(), img.get_height());
        float3 c = img.read(uint2(clamp(p, int2(0), size - 1))).rgb;
        return dot(c, float3(0.2126, 0.7152, 0.0722));
    }

    // A threadgroup is 16 x 16 pixels. It first loads the luma of its pixels and a two-pixel border into
    // threadgroup memory (20 x 20), so each source pixel is read from the texture about once, not nine times or more.
    constant uint tileSide = 16;
    constant uint lumaSide = tileSide + 4;
    constant uint smoothSide = tileSide + 2;

    static void loadTile(texture2d<float, access::read> img, threadgroup float *tile, uint2 group, uint2 local) {
        int2 origin = int2(group * tileSide) - 2;
        for (uint i = local.y * tileSide + local.x; i < lumaSide * lumaSide; i += tileSide * tileSide) {
            tile[i] = lumaAt(img, origin + int2(i % lumaSide, i / lumaSide));
        }
        threadgroup_barrier(mem_flags::mem_threadgroup);
    }

    // The mask stores the square root of the strength, which is a luma step: a clean jump of d between two
    // neighbors reads d in both kernels.
    static void store(texture2d<float, access::write> out, uint2 gid, float strength) {
        out.write(float4(sqrt(saturate(strength)), 0, 0, 0), gid);
    }

    // Edges: Sobel on luma that was smoothed by a 3 x 3 binomial first. Noise is mostly gone before the gradient;
    // an edge is still two or three pixels wide. A clean step of d peaks at 3d in Sobel's units.
    kernel void peakEdges(texture2d<float, access::read> img [[texture(0)]],
                          texture2d<float, access::write> out [[texture(1)]],
                          uint2 gid [[thread_position_in_grid]],
                          uint2 local [[thread_position_in_threadgroup]],
                          uint2 group [[threadgroup_position_in_grid]]) {
        threadgroup float tile[lumaSide * lumaSide];
        threadgroup float smooth[smoothSide * smoothSide];
        loadTile(img, tile, group, local);
        for (uint i = local.y * tileSide + local.x; i < smoothSide * smoothSide; i += tileSide * tileSide) {
            uint c = (i / smoothSide + 1) * lumaSide + (i % smoothSide + 1);
            smooth[i] = (tile[c - lumaSide - 1] + 2.0 * tile[c - lumaSide] + tile[c - lumaSide + 1]
                       + 2.0 * tile[c - 1] + 4.0 * tile[c] + 2.0 * tile[c + 1]
                       + tile[c + lumaSide - 1] + 2.0 * tile[c + lumaSide] + tile[c + lumaSide + 1]) / 16.0;
        }
        threadgroup_barrier(mem_flags::mem_threadgroup);
        if (gid.x >= out.get_width() || gid.y >= out.get_height()) return;
        uint c = (local.y + 1) * smoothSide + local.x + 1;
        float tl = smooth[c - smoothSide - 1], t = smooth[c - smoothSide], tr = smooth[c - smoothSide + 1];
        float l = smooth[c - 1], r = smooth[c + 1];
        float bl = smooth[c + smoothSide - 1], b = smooth[c + smoothSide], br = smooth[c + smoothSide + 1];
        float gx = (tr + 2.0 * r + br) - (tl + 2.0 * l + bl);
        float gy = (bl + 2.0 * b + br) - (tl + 2.0 * t + tr);
        store(out, gid, length(float2(gx, gy)) / 3.0);
    }

    // Fine detail: an 8-neighbor Laplacian of the luma after the same light 3 x 3 smoothing. Without it the Laplacian
    // answers 2.8 times the noise (a photo at ISO 6400 lights up from edge to edge); with it, detail down to a pixel or
    // two still shows and sensor noise mostly does not. A Laplacian is still about 3 times as sensitive to noise as the
    // Sobel above for the same response to an edge, so it is divided by 2.3 (a clean step of d reads 0.33d): the same
    // slider position then tolerates about the same amount of noise in both modes.
    kernel void peakFine(texture2d<float, access::read> img [[texture(0)]],
                         texture2d<float, access::write> out [[texture(1)]],
                         uint2 gid [[thread_position_in_grid]],
                         uint2 local [[thread_position_in_threadgroup]],
                         uint2 group [[threadgroup_position_in_grid]]) {
        threadgroup float tile[lumaSide * lumaSide];
        threadgroup float smooth[smoothSide * smoothSide];
        loadTile(img, tile, group, local);
        for (uint i = local.y * tileSide + local.x; i < smoothSide * smoothSide; i += tileSide * tileSide) {
            uint c = (i / smoothSide + 1) * lumaSide + (i % smoothSide + 1);
            smooth[i] = (tile[c - lumaSide - 1] + 2.0 * tile[c - lumaSide] + tile[c - lumaSide + 1]
                       + 2.0 * tile[c - 1] + 4.0 * tile[c] + 2.0 * tile[c + 1]
                       + tile[c + lumaSide - 1] + 2.0 * tile[c + lumaSide] + tile[c + lumaSide + 1]) / 16.0;
        }
        threadgroup_barrier(mem_flags::mem_threadgroup);
        if (gid.x >= out.get_width() || gid.y >= out.get_height()) return;
        uint c = (local.y + 1) * smoothSide + local.x + 1;
        float around = smooth[c - smoothSide - 1] + smooth[c - smoothSide] + smooth[c - smoothSide + 1]
                     + smooth[c - 1] + smooth[c + 1]
                     + smooth[c + smoothSide - 1] + smooth[c + smoothSide] + smooth[c + smoothSide + 1];
        store(out, gid, abs(8.0 * smooth[c] - around) / 2.3);
    }

    // Level 1: how many of the (up to 3 x 3 at an odd edge) source pixels passed the threshold.
    kernel void peakCountFirst(texture2d<float, access::read> src [[texture(0)]],
                               texture2d<float, access::write> dst [[texture(1)]],
                               constant float &threshold [[buffer(0)]],
                               uint2 gid [[thread_position_in_grid]]) {
        uint dw = dst.get_width(), dh = dst.get_height();
        if (gid.x >= dw || gid.y >= dh) return;
        uint sw = src.get_width(), sh = src.get_height();
        uint x0 = min(gid.x * 2, sw - 1), y0 = min(gid.y * 2, sh - 1);
        uint x1 = gid.x == dw - 1 ? sw - 1 : min(x0 + 1, sw - 1);
        uint y1 = gid.y == dh - 1 ? sh - 1 : min(y0 + 1, sh - 1);
        float count = 0;
        for (uint y = y0; y <= y1; y++) {
            for (uint x = x0; x <= x1; x++) count += src.read(uint2(x, y)).r >= threshold ? 1.0 : 0.0;
        }
        dst.write(float4(count / 255.0, 0, 0, 0), gid);
    }

    // Higher levels: the sum of the counts below, up to 255.
    kernel void peakCountNext(texture2d<float, access::read> src [[texture(0)]],
                              texture2d<float, access::write> dst [[texture(1)]],
                              constant float &threshold [[buffer(0)]],
                              uint2 gid [[thread_position_in_grid]]) {
        uint dw = dst.get_width(), dh = dst.get_height();
        if (gid.x >= dw || gid.y >= dh) return;
        uint sw = src.get_width(), sh = src.get_height();
        uint x0 = min(gid.x * 2, sw - 1), y0 = min(gid.y * 2, sh - 1);
        uint x1 = gid.x == dw - 1 ? sw - 1 : min(x0 + 1, sw - 1);
        uint y1 = gid.y == dh - 1 ? sh - 1 : min(y0 + 1, sh - 1);
        float sum = 0;
        for (uint y = y0; y <= y1; y++) {
            for (uint x = x0; x <= x1; x++) sum += src.read(uint2(x, y)).r;
        }
        dst.write(float4(min(sum, 1.0), 0, 0, 0), gid);
    }

    struct VertexOut {
        float4 position [[position]];
        float2 uv;
    };
    struct PeakParams {
        float4 color;
        float threshold;
        uint levels;
    };

    // Paints the color where the picture is sharp under this screen pixel.
    // Zoomed in, or out by less than 2x, it reads the strength of the source pixels under it and takes the largest.
    // Zoomed out further, a screen pixel covers a block of source pixels, and one noisy pixel in it proves nothing:
    // it reads the count of passing pixels at the level that matches the block, at 9 points across the footprint,
    // and paints when some point has at least 1/10 of the block's pixels, and at least 3.
    fragment float4 peakingFragment(VertexOut in [[stage_in]], texture2d<float, access::read> mask [[texture(0)]],
                                    constant PeakParams &p [[buffer(0)]]) {
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
        float strongest = 0;
        for (int dy = -taps; dy <= taps; dy++) {
            for (int dx = -taps; dx <= taps; dx++) {
                float2 texel = in.uv * base + float2(dx, dy) * reach;
                uint2 q = uint2(clamp(floor(texel / scale), float2(0), size - 1));
                strongest = max(strongest, mask.read(q, lod).r);
            }
        }
        bool sharp;
        if (lod == 0) {
            sharp = strongest >= p.threshold;
        } else {
            float needed = max(3.0, scale * scale / 10.0);
            sharp = strongest * 255.0 >= needed - 0.5;
        }
        if (!sharp) discard_fragment();
        return float4(p.color.rgb, 1.0);
    }
    """
}

extension LoupeGPU {
    /// The share of pixels (0...1) that focus peaking would mark on `image` with `style`. Runs the same compute pass
    /// as the overlay, so it is how frames of a focus bracket are ranked, and what the tests measure.
    public func peakingDensity(of image: PreparedImage, style: PeakingStyle) -> Double? {
        guard let mask = peakingMaskBytes(of: image, mode: style.mode, style: style), !mask.bytes.isEmpty else { return nil }
        let threshold = PeakingThreshold.stored(sensitivity: style.sensitivity, mode: style.mode)
        // The mask is 8-bit: a pixel is marked when its byte, as a fraction, reaches the threshold.
        let cut = Int((threshold * 255).rounded(.up))
        var marked = 0
        for byte in mask.bytes where Int(byte) >= cut { marked += 1 }
        return Double(marked) / Double(mask.bytes.count)
    }

    /// The mask's level 0 or a pyramid level as bytes, after running the compute passes. For tests and the density.
    func peakingMaskBytes(of image: PreparedImage, mode: PeakingMode, style: PeakingStyle? = nil, level: Int = 0) -> (bytes: [UInt8], width: Int, height: Int, levels: Int)? {
        let style = style ?? PeakingStyle(mode: mode)
        guard let peaking, let buffer = queue.makeCommandBuffer(),
              let mask = peaking.makeMask(for: image, mode: mode, threshold: PeakingThreshold.stored(sensitivity: style.sensitivity, mode: mode),
                                          reusing: nil, in: buffer),
              level >= 0, level < mask.levels else { return nil }
        let w = max(1, mask.width >> level), h = max(1, mask.height >> level)
        guard let staging = device.makeBuffer(length: w * h, options: .storageModeShared),
              let blit = buffer.makeBlitCommandEncoder() else { return nil }
        blit.copy(from: mask.texture, sourceSlice: 0, sourceLevel: level, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                  sourceSize: MTLSize(width: w, height: h, depth: 1), to: staging, destinationOffset: 0,
                  destinationBytesPerRow: w, destinationBytesPerImage: w * h)
        blit.endEncoding()
        buffer.commit()
        buffer.waitUntilCompleted()
        return (Array(UnsafeBufferPointer(start: staging.contents().assumingMemoryBound(to: UInt8.self), count: w * h)), w, h, mask.levels)
    }
}
