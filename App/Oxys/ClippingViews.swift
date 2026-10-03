import Canvas
import SwiftUI

/// The clipped share of the frame, for each overlay that is on, and which pixels were analyzed (V-07). Bottom left,
/// above the peaking label. Text and an icon, never color alone.
struct ClippingReadout: View {
    let label: LoupeController.ClippingLabel

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(label.rows, id: \.title) { row in
                PlateLabel(text: "\(row.title) \(row.value)", systemImage: row.symbol, tint: Plate.secondary)
            }
            Text(label.source).foregroundStyle(Plate.secondary).font(.caption)
        }
        .probeContent()
        .font(.callout.weight(.semibold).monospacedDigit())
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .infoPlate(cornerRadius: 8)
        .contrastProbe("clipping", .plate, shape: .rounded(8), uses: [.text(.secondary)])
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        .padding(.bottom, label.stackedOverPeaking ? 74 : 34)
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label.spoken)
    }
}

/// `⌥H`: the two thresholds as whole percents. Return or Esc closes it; ↑ and ↓ step a focused field by 1.
struct ClippingThresholdsPopover: View {
    @AppStorage(ClippingSettings.highlightKey) private var highlight = ClippingThresholds.defaultHighlight
    @AppStorage(ClippingSettings.shadowKey) private var shadow = ClippingThresholds.defaultShadow
    @AppStorage(ClippingSettings.patternKey) private var pattern = false
    let close: () -> Void
    @FocusState private var focus: Field?
    private enum Field { case highlight, shadow }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Clipping thresholds").font(.headline)
            LabeledContent("Highlights from") {
                percentField($highlight, ClippingThresholds.highlightRange, .highlight, label: "Highlight threshold, percent")
            }
            LabeledContent("Shadows up to") {
                percentField($shadow, ClippingThresholds.shadowRange, .shadow, label: "Shadow threshold, percent")
            }
            Toggle("Stripes instead of solid color", isOn: $pattern)
            Text("A highlight is a pixel with any channel at or above its threshold; a shadow has all channels at or below.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Defaults") { highlight = ClippingThresholds.defaultHighlight; shadow = ClippingThresholds.defaultShadow }
                Spacer()
                Button("Done", action: close).keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 290)
        .onAppear { focus = .highlight }
        .onExitCommand(perform: close)
    }

    private func percentField(_ value: Binding<Int>, _ range: ClosedRange<Int>, _ field: Field, label: String) -> some View {
        HStack(spacing: 4) {
            TextField(label, value: value, format: .number)
                .multilineTextAlignment(.trailing)
                .frame(width: 52)
                .focused($focus, equals: field)
                .onChange(of: value.wrappedValue) { _, new in
                    let clamped = min(max(new, range.lowerBound), range.upperBound)
                    if clamped != new { value.wrappedValue = clamped }
                }
                .onKeyPress(.upArrow) { value.wrappedValue = min(value.wrappedValue + 1, range.upperBound); return .handled }
                .onKeyPress(.downArrow) { value.wrappedValue = max(value.wrappedValue - 1, range.lowerBound); return .handled }
                .accessibilityLabel(label)
            Text("%")
            Stepper("", value: value, in: range).labelsHidden().accessibilityHidden(true)
        }
    }
}
