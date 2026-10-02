import SwiftUI

/// Says that focus peaking is on, in which mode, and whether the preview or the RAW was analyzed (V-06). Bottom left,
/// above the info strip, on the same plate as the truth badge. Text and an icon, never color alone.
struct PeakingBadgeView: View {
    let label: LoupeController.PeakingLabel

    var body: some View {
        PlateLabel(text: label.text, systemImage: "scope", tint: Plate.secondary)
            .font(.callout.weight(.semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .infoPlate(cornerRadius: 8)
            .padding(12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            .padding(.bottom, 34)
            .allowsHitTesting(false)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(label.spoken)
    }
}
