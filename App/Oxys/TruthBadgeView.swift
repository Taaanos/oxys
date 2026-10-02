import Imaging
import SwiftUI

/// The truth badge (V-05): which pixels are on screen, bottom right on a plate. A warning has a triangle and the
/// words, so it never rests on color. It is a cut, not an animation. Compare (V-08) puts one on each pane.
struct TruthBadgeView: View {
    let badge: TruthBadge

    var body: some View {
        Label(badge.text, systemImage: badge.isWarning ? "exclamationmark.triangle.fill" : "checkmark.seal")
            .labelStyle(PlateIconStyle(tint: badge.isWarning ? Plate.warning : Plate.secondary))
            .font(.callout.weight(.semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .infoPlate(cornerRadius: 8)
            .padding(12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            .padding(.bottom, 34)
            .allowsHitTesting(false)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(badge.spoken)
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
