import SwiftUI

/// Says that focus peaking is on, in which mode, and whether the preview or the RAW was analyzed (V-06). Bottom left,
/// above the info strip, on the same glass as the truth badge. Text and an icon, never color alone.
struct PeakingBadgeView: View {
    let label: LoupeController.PeakingLabel

    var body: some View {
        PlateLabel(text: label.text, systemImage: "scope", tint: Plate.secondary)
            .probeContent()
            .font(.callout.weight(.semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .glassPlate()
            .contrastProbe("peaking", .glass, shape: .capsule, uses: [.text(.secondary)])
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(label.spoken)
    }
}
