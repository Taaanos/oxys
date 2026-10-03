import Imaging
import SwiftUI

/// Luminance (filled gray) with R, G and B (lines) on a backing plate, the clipped shares at both ends, and
/// the source's name. One view for Loupe's overlay and the inspector (M-18).
struct HistogramView: View {
    let histogram: Histogram
    /// True for the corner copy on the photo (D-07): glass. The inspector copy keeps the black plate.
    var onPhoto = false

    private static let width: CGFloat = 256, height: CGFloat = 80

    private var spoken: String {
        "Histogram of the \(histogram.source.rawValue.lowercased()). Shadows clipped \(Self.percent(histogram.clippedShadowsPercent)), highlights clipped \(Self.percent(histogram.clippedHighlightsPercent))."
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Canvas { context, size in
                let peak = Self.peak(histogram)
                func path(_ bins: [UInt32], closed: Bool) -> Path {
                    var path = Path()
                    let step = size.width / CGFloat(Histogram.binCount)
                    for (i, count) in bins.enumerated() {
                        // Square root keeps a tall spike from flattening the rest, as most histograms do.
                        let h = size.height * CGFloat((Double(count) / peak).squareRoot())
                        let point = CGPoint(x: (CGFloat(i) + 0.5) * step, y: size.height - h)
                        if i == 0 { path.move(to: closed ? CGPoint(x: 0, y: size.height) : point) }
                        path.addLine(to: point)
                    }
                    if closed { path.addLine(to: CGPoint(x: size.width, y: size.height)); path.closeSubpath() }
                    return path
                }
                context.fill(path(histogram.luminance, closed: true), with: .color(.white.opacity(0.35)))
                for (bins, color) in [(histogram.red, Color.red), (histogram.green, .green), (histogram.blue, .blue)] {
                    context.stroke(path(bins, closed: false), with: .color(color.opacity(0.85)), lineWidth: 1)
                }
            }
            .frame(width: Self.width, height: Self.height)
            HStack {
                Text("◀ \(Self.percent(histogram.clippedShadowsPercent))")
                    .foregroundStyle(histogram.clippedShadowsPercent > 0 ? Color.cyan : Plate.secondary)
                Spacer()
                Text(histogram.source.rawValue).foregroundStyle(Plate.secondary)
                Spacer()
                Text("\(Self.percent(histogram.clippedHighlightsPercent)) ▶")
                    .foregroundStyle(histogram.clippedHighlightsPercent > 0 ? Color.orange : Plate.secondary)
            }
            .font(.caption.monospacedDigit())
            .frame(width: Self.width)
        }
        .probeContent()
        .padding(10)
        .plateStyle(onPhoto: onPhoto)
        .contrastProbe("histogram", onPhoto ? .glass : .plate, shape: .rounded(onPhoto ? 12 : 8), uses: [.text(.secondary), .text(.warning), .text(.cyan)])
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spoken)
    }

    /// Tallest bin among the four; the end bins count like any other, so clipping shows as a spike.
    private static func peak(_ h: Histogram) -> Double {
        Double(max(1, [h.luminance, h.red, h.green, h.blue].compactMap { $0.max() }.max() ?? 1))
    }

    private static func percent(_ value: Double) -> String {
        value == 0 ? "0%" : value < 0.1 ? "<0.1%" : String(format: "%.1f%%", value)
    }
}

private extension View {
    @ViewBuilder func plateStyle(onPhoto: Bool) -> some View {
        if onPhoto { glassPlate(in: .rect(cornerRadius: 12)) } else { infoPlate() }
    }
}
