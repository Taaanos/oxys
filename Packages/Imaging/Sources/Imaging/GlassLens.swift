import CoreGraphics
import Foundation

/// A glass lens over a small picture (V-20, the film strip's active cell): the middle stays flat and sharp, and a
/// rim along the edge bends the picture like the bevel of a thick piece of glass, with a light edge on the top left
/// and a darker one on the bottom right. The shape is a rounded square. Plain arithmetic on a 160 px bitmap, about a
/// millisecond, done once per photo that becomes active; nothing runs while the strip is idle.
public enum GlassLens {
    public struct Style: Sendable, Equatable {
        /// Width of the bending rim, as a share of the edge.
        public var rimWidth = 0.17
        /// How far, as a share of the edge, the picture is pulled in at the very edge of the glass.
        public var strength = 0.11
        /// Corner radius as a share of the edge.
        public var cornerRadius = 0.16
        /// Brightness added on the lit rim and taken off the shaded one (0 to 1).
        public var highlight = 0.40
        public var shade = 0.22
        public init() {}
    }

    /// `image` is fitted inside an `edge` × `edge` square over `background` (gray 0 to 1) and then bent. `overlay` draws
    /// into the square first (a bitmap context of `edge` × `edge` pixels, origin bottom left) and is bent as well. Returns nil
    /// when the bitmap cannot be made. Pixels outside the rounded square are transparent.
    public static func apply(to image: CGImage, edge: Int, background: Double, style: Style = Style(),
                             overlay: ((CGContext) -> Void)? = nil) -> CGImage? {
        guard edge >= 8, image.width > 0, image.height > 0 else { return nil }
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let info = CGImageAlphaInfo.premultipliedLast.rawValue
        guard let ctx = CGContext(data: nil, width: edge, height: edge, bitsPerComponent: 8, bytesPerRow: edge * 4,
                                  space: space, bitmapInfo: info) else { return nil }
        ctx.setFillColor(CGColor(gray: background, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: edge, height: edge))
        let scale = min(Double(edge) / Double(image.width), Double(edge) / Double(image.height))
        let w = Double(image.width) * scale, h = Double(image.height) * scale
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: (Double(edge) - w) / 2, y: (Double(edge) - h) / 2, width: w, height: h))
        // Marks drawn here sit under the glass: the rim bends them with the picture.
        overlay?(ctx)
        guard let source = ctx.data?.assumingMemoryBound(to: UInt8.self),
              let out = CGContext(data: nil, width: edge, height: edge, bitsPerComponent: 8, bytesPerRow: edge * 4,
                                  space: space, bitmapInfo: info),
              let dest = out.data?.assumingMemoryBound(to: UInt8.self) else { return nil }

        let n = Double(edge)
        let half = n / 2
        let radius = style.cornerRadius * n
        let rim = max(style.rimWidth * n, 1)
        let pull = style.strength * n
        // Light from the top left. The bitmap's first row is the top one, so "up" is -y.
        let lx = -0.6, ly = -0.8
        for row in 0..<edge {
            for col in 0..<edge {
                let px = Double(col) + 0.5 - half
                let py = Double(row) + 0.5 - half
                // Signed distance to the rounded square (negative inside) and the outward normal.
                let qx = abs(px) - (half - radius), qy = abs(py) - (half - radius)
                let sx: Double = px < 0 ? -1 : 1, sy: Double = py < 0 ? -1 : 1
                let outside = (max(qx, 0) * max(qx, 0) + max(qy, 0) * max(qy, 0)).squareRoot()
                let sd = outside + min(max(qx, qy), 0) - radius
                let alpha = min(max(0.5 - sd, 0), 1)
                let o = (row * edge + col) * 4
                guard alpha > 0 else {
                    dest[o] = 0; dest[o + 1] = 0; dest[o + 2] = 0; dest[o + 3] = 0
                    continue
                }
                var gx = 0.0, gy = 0.0
                if qx > 0, qy > 0 {
                    let len = outside
                    gx = sx * qx / len; gy = sy * qy / len
                } else if qx > qy { gx = sx } else { gy = sy }
                // Rim profile: 1 at the edge, 0 at the inner end of the rim, with an ease so the bend starts gently.
                let depth = -sd
                let t = min(max(1 - depth / rim, 0), 1)
                let bend = pull * t * t
                // Sample from further in: the edge shows content from inside, like the bevel of thick glass.
                let sxp = (px - gx * bend) + half - 0.5
                let syp = (py - gy * bend) + half - 0.5
                var r = 0.0, g = 0.0, b = 0.0
                sample(source, edge, sxp, syp, &r, &g, &b)
                // Light on the lit side of the rim, shade on the other, and a fine bright line at the very edge.
                let facing = gx * lx + gy * ly
                let lit = t * t * t * max(facing, 0) * style.highlight
                let dark = t * t * max(-facing, 0) * style.shade
                let line = max(1 - depth / 1.6, 0) * 0.22
                let add = lit + line - dark
                r = min(max(r + (add > 0 ? (1 - r) * add : r * add), 0), 1)
                g = min(max(g + (add > 0 ? (1 - g) * add : g * add), 0), 1)
                b = min(max(b + (add > 0 ? (1 - b) * add : b * add), 0), 1)
                dest[o] = UInt8((r * alpha * 255).rounded())
                dest[o + 1] = UInt8((g * alpha * 255).rounded())
                dest[o + 2] = UInt8((b * alpha * 255).rounded())
                dest[o + 3] = UInt8((alpha * 255).rounded())
            }
        }
        return out.makeImage()
    }

    /// Bilinear sample of an opaque RGBA bitmap, clamped at the edges. `x` and `y` are in pixel units, with whole
    /// numbers at pixel centers.
    private static func sample(_ p: UnsafePointer<UInt8>, _ edge: Int, _ x: Double, _ y: Double,
                               _ r: inout Double, _ g: inout Double, _ b: inout Double) {
        let maxIndex = Double(edge - 1)
        let fx = min(max(x, 0), maxIndex), fy = min(max(y, 0), maxIndex)
        let x0 = Int(fx), y0 = Int(fy)
        let x1 = min(x0 + 1, edge - 1), y1 = min(y0 + 1, edge - 1)
        let tx = fx - Double(x0), ty = fy - Double(y0)
        func at(_ cx: Int, _ cy: Int, _ c: Int) -> Double { Double(p[(cy * edge + cx) * 4 + c]) / 255 }
        func mix(_ c: Int) -> Double {
            let top = at(x0, y0, c) * (1 - tx) + at(x1, y0, c) * tx
            let bottom = at(x0, y1, c) * (1 - tx) + at(x1, y1, c) * tx
            return top * (1 - ty) + bottom * ty
        }
        r = mix(0); g = mix(1); b = mix(2)
    }
}
