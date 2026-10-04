import CoreGraphics
import Dispatch
import Foundation
import Synchronization

/// A glass lens over a small picture (V-20, D-13: the film strip's and Grid's active cell): the middle stays flat and
/// sharp, and a rim along the edge bends the picture like the bevel of a thick piece of glass, with a light edge on
/// the top left and a darker one on the bottom right. The shape is a rounded square.
///
/// How the bend and the light fall depends on the size and the style only, not on the picture. So they are worked
/// out once per size (the plan, about 10 ms at 960 px) and kept. After that a lens is a copy of the picture plus a
/// sample for each pixel of the rim, spread over the cores. Nothing runs while nothing changes.
public enum GlassLens {
    public struct Style: Sendable, Hashable {
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
        public init(rimWidth: Double, strength: Double, cornerRadius: Double) {
            self.rimWidth = rimWidth
            self.strength = strength
            self.cornerRadius = cornerRadius
        }
    }

    /// `image` is fitted inside an `edge` × `edge` square over `background` (gray 0 to 1) and then bent; without an
    /// image the square is the background alone (a cell whose thumbnail has not loaded still shows its lens).
    /// `overlay` draws into the square first (a bitmap context of `edge` × `edge` pixels, origin bottom left) and is
    /// bent as well. Returns nil when the bitmap cannot be made. Pixels outside the rounded square are transparent.
    public static func apply(to image: CGImage?, edge: Int, background: Double, style: Style = Style(),
                             overlay: ((CGContext) -> Void)? = nil) -> CGImage? {
        guard edge >= 8, image.map({ $0.width > 0 && $0.height > 0 }) ?? true else { return nil }
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let info = CGImageAlphaInfo.premultipliedLast.rawValue
        guard let ctx = CGContext(data: nil, width: edge, height: edge, bitsPerComponent: 8, bytesPerRow: edge * 4,
                                  space: space, bitmapInfo: info) else { return nil }
        ctx.setFillColor(CGColor(gray: background, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: edge, height: edge))
        if let image {
            let scale = min(Double(edge) / Double(image.width), Double(edge) / Double(image.height))
            let w = Double(image.width) * scale, h = Double(image.height) * scale
            ctx.interpolationQuality = .high
            ctx.draw(image, in: CGRect(x: (Double(edge) - w) / 2, y: (Double(edge) - h) / 2, width: w, height: h))
        }
        // Marks drawn here sit under the glass: the rim bends them with the picture.
        overlay?(ctx)
        guard let source = ctx.data?.assumingMemoryBound(to: UInt8.self),
              let out = CGContext(data: nil, width: edge, height: edge, bitsPerComponent: 8, bytesPerRow: edge * 4,
                                  space: space, bitmapInfo: info),
              let dest = out.data?.assumingMemoryBound(to: UInt8.self) else { return nil }

        // The flat middle is the picture as it is; the plan overwrites the rim and the corners.
        dest.update(from: source, count: edge * edge * 4)
        let plan = Plans.plan(edge: edge, style: style)
        let buffers = Buffers(source: UnsafePointer(source), dest: dest, edge: edge)
        plan.entries.withUnsafeBufferPointer { entries in
            let all = Entries(base: entries.baseAddress, count: entries.count)
            let chunk = 16_384
            let chunks = (all.count + chunk - 1) / chunk
            if chunks <= 1 {
                render(all, from: 0, to: all.count, buffers)
            } else {
                DispatchQueue.concurrentPerform(iterations: chunks) { i in
                    render(all, from: i * chunk, to: min((i + 1) * chunk, all.count), buffers)
                }
            }
        }
        return out.makeImage()
    }

    // MARK: plan

    /// One pixel that is not a plain copy: where its color comes from, how much light it gets and how much of it is
    /// inside the shape (0 outside the rounded corners, between 0 and 1 on the very edge).
    private struct Entry {
        var offset: Int32
        var x: Float
        var y: Float
        var add: Float
        var alpha: Float
    }

    private struct Buffers: @unchecked Sendable {
        let source: UnsafePointer<UInt8>
        let dest: UnsafeMutablePointer<UInt8>
        let edge: Int
    }

    private struct Entries: @unchecked Sendable {
        let base: UnsafePointer<Entry>?
        let count: Int
    }

    private final class Plan: Sendable {
        let entries: [Entry]
        init(entries: [Entry]) { self.entries = entries }
    }

    private struct PlanKey: Hashable { let edge: Int; let style: Style }

    private enum Plans {
        private static let state = Mutex<(plans: [PlanKey: Plan], order: [PlanKey])>(([:], []))
        /// A Grid keeps at most five sizes and the strip one; a few more cover a window moved between screens.
        private static let limit = 8

        static func plan(edge: Int, style: Style) -> Plan {
            let key = PlanKey(edge: edge, style: style)
            if let hit = state.withLock({ $0.plans[key] }) { return hit }
            let made = Plan(entries: build(edge: edge, style: style))
            state.withLock { state in
                state.plans[key] = made
                state.order.removeAll { $0 == key }
                state.order.append(key)
                while state.order.count > limit { state.plans[state.order.removeFirst()] = nil }
            }
            return made
        }
    }

    private static func build(edge: Int, style: Style) -> [Entry] {
        let n = Double(edge)
        let half = n / 2
        let radius = style.cornerRadius * n
        let rim = max(style.rimWidth * n, 1)
        let pull = style.strength * n
        // Light from the top left. The bitmap's first row is the top one, so "up" is -y.
        let lx = -0.6, ly = -0.8
        // Further than this from every edge a pixel is flat, whatever the corner radius.
        let band = Int((rim + radius).rounded(.up)) + 1
        var entries: [Entry] = []
        entries.reserveCapacity(Int(4 * n * Double(band)))
        for row in 0..<edge {
            let fullRow = row < band || row >= edge - band
            var col = 0
            while col < edge {
                if !fullRow, col == band { col = edge - band }
                defer { col += 1 }
                let px = Double(col) + 0.5 - half
                let py = Double(row) + 0.5 - half
                // Signed distance to the rounded square (negative inside) and the outward normal.
                let qx = abs(px) - (half - radius), qy = abs(py) - (half - radius)
                let sx: Double = px < 0 ? -1 : 1, sy: Double = py < 0 ? -1 : 1
                let outside = (max(qx, 0) * max(qx, 0) + max(qy, 0) * max(qy, 0)).squareRoot()
                let sd = outside + min(max(qx, qy), 0) - radius
                let alpha = min(max(0.5 - sd, 0), 1)
                let offset = Int32(row * edge + col)
                guard alpha > 0 else {
                    entries.append(Entry(offset: offset, x: 0, y: 0, add: 0, alpha: 0))
                    continue
                }
                var gx = 0.0, gy = 0.0
                if qx > 0, qy > 0 {
                    gx = sx * qx / outside; gy = sy * qy / outside
                } else if qx > qy { gx = sx } else { gy = sy }
                // Rim profile: 1 at the edge, 0 at the inner end of the rim, with an ease so the bend starts gently.
                let depth = -sd
                let t = min(max(1 - depth / rim, 0), 1)
                let line = max(1 - depth / 1.6, 0) * 0.22
                guard alpha < 1 || t > 0 || line > 0 else { continue }
                let bend = pull * t * t
                // Sample from further in: the edge shows content from inside, like the bevel of thick glass.
                let sxp = (px - gx * bend) + half - 0.5
                let syp = (py - gy * bend) + half - 0.5
                // Light on the lit side of the rim, shade on the other, and a fine bright line at the very edge.
                let facing = gx * lx + gy * ly
                let lit = t * t * t * max(facing, 0) * style.highlight
                let dark = t * t * max(-facing, 0) * style.shade
                entries.append(Entry(offset: offset, x: Float(sxp), y: Float(syp), add: Float(lit + line - dark), alpha: Float(alpha)))
            }
        }
        return entries
    }

    // MARK: render

    private static func render(_ entries: Entries, from lower: Int, to upper: Int, _ buffers: Buffers) {
        guard let base = entries.base else { return }
        let edge = buffers.edge, source = buffers.source, dest = buffers.dest
        let maxIndex = Float(edge - 1)
        for i in lower..<upper {
            let e = base[i]
            let o = Int(e.offset) * 4
            guard e.alpha > 0 else {
                dest[o] = 0; dest[o + 1] = 0; dest[o + 2] = 0; dest[o + 3] = 0
                continue
            }
            // Bilinear sample of the opaque bitmap, clamped at the edges.
            let fx = min(max(e.x, 0), maxIndex), fy = min(max(e.y, 0), maxIndex)
            let x0 = Int(fx), y0 = Int(fy)
            let x1 = min(x0 + 1, edge - 1), y1 = min(y0 + 1, edge - 1)
            let tx = fx - Float(x0), ty = fy - Float(y0)
            let p00 = (y0 * edge + x0) * 4, p10 = (y0 * edge + x1) * 4, p01 = (y1 * edge + x0) * 4, p11 = (y1 * edge + x1) * 4
            let w00 = (1 - tx) * (1 - ty), w10 = tx * (1 - ty), w01 = (1 - tx) * ty, w11 = tx * ty
            let add = e.add
            for c in 0..<3 {
                let mixed = (Float(source[p00 + c]) * w00 + Float(source[p10 + c]) * w10
                             + Float(source[p01 + c]) * w01 + Float(source[p11 + c]) * w11) / 255
                let lit = add > 0 ? mixed + (1 - mixed) * add : mixed + mixed * add
                dest[o + c] = UInt8((min(max(lit, 0), 1) * e.alpha * 255).rounded())
            }
            dest[o + 3] = UInt8((e.alpha * 255).rounded())
        }
    }
}
