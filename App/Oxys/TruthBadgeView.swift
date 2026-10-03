import Imaging
import SwiftUI

/// The truth badge (V-05): which pixels are on screen, bottom right on glass. It shows only while the info strip is
/// off: the strip carries the badge text itself. A warning has a triangle and the words, so it never rests on color.
/// It is a cut, not an animation. Compare (V-08) puts one on each pane.
struct TruthBadgeView: View {
    let badge: TruthBadge

    var body: some View {
        Group {
            if badge.isWarning {
                Label(badge.text, systemImage: "exclamationmark.triangle.fill")
                    .labelStyle(PlateIconStyle(tint: Plate.warning))
            } else {
                Text(badge.text).foregroundStyle(.white)
            }
        }
        .probeContent()
        .font(.callout.weight(.semibold))
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .glassPlate()
        .contrastProbe("truth-badge", .glass, shape: .capsule, uses: [.text(.white), .mark(.warning)])
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(badge.spoken)
    }
}

/// Says that auto-advance is on (V-11): text and an icon, never color alone. Above the info strip in Loupe and
/// Compare, bottom right in Grid.
struct AutoAdvanceBadge: View {
    var body: some View {
        PlateLabel(text: "Auto-advance", systemImage: "forward.end.fill", tint: Plate.secondary)
            .probeContent()
            .font(.callout.weight(.semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .glassPlate()
            .contrastProbe("auto-advance", .glass, shape: .capsule, uses: [.text(.secondary)])
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Auto-advance is on. Shift applies a rating without advancing.")
    }
}

private struct PlateIconStyle: LabelStyle {
    let tint: Color

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) {
            configuration.icon.foregroundStyle(tint)
            configuration.title.foregroundStyle(.white)
        }
    }
}
