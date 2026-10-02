import Imaging
import SwiftUI

/// The truth badge (V-05): which pixels are on screen, bottom right on a plate. The Auto-advance plate (V-11) sits
/// under it when that mode is on, so the truth badge moves up to make room. A warning has a triangle and the
/// words, so it never rests on color. It is a cut, not an animation. Compare (V-08) puts one on each pane.
struct TruthBadgeView: View {
    let badge: TruthBadge?
    var autoAdvance = false

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            if let badge {
                Group {
                    if badge.isWarning {
                        Label(badge.text, systemImage: "exclamationmark.triangle.fill")
                            .labelStyle(PlateIconStyle(tint: Plate.warning))
                    } else {
                        Text(badge.text).foregroundStyle(.white)
                    }
                }
                .font(.callout.weight(.semibold))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .infoPlate(cornerRadius: 8)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(badge.spoken)
            }
            if autoAdvance { AutoAdvanceBadge() }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        .padding(.bottom, 34)
        .allowsHitTesting(false)
    }
}

/// Says that auto-advance is on (V-11): text and an icon, never color alone.
struct AutoAdvanceBadge: View {
    var body: some View {
        PlateLabel(text: "Auto-advance", systemImage: "forward.end.fill", tint: Plate.secondary)
            .font(.callout.weight(.semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .infoPlate(cornerRadius: 8)
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
