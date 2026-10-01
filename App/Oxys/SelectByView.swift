import AppKit
import Library
import SwiftUI

/// The ⌥⌘A popover (M-19): a row of stars and a row of label circles, like the filter strip in other cullers.
/// Choosing something selects at once, so the count in the subtitle shows what the rule matches.
/// Rating: a click selects that many stars exactly, `⇧` that many or fewer, `⌥` that many or more; a second click
/// clears the row. Label: a click selects that label, the gray circle means no label. The two rows combine.
/// Keys: `1`–`5`, `0` (unrated) and `X` (rejected) pick the rating, `6`–`9` and `-`… the label; `Return` or `Esc` closes.
struct SelectByView: View {
    let apply: (SelectionCriteria) -> Void
    let done: () -> Void

    @State private var criteria = SelectionCriteria()
    @FocusState private var focused: Bool

    private static let labels: [(SelectionCriteria.Label, ColorLabel?, String)] = [
        (.unlabeled, nil, "No label"), (.color(.red), .red, "Red"), (.color(.yellow), .yellow, "Yellow"),
        (.color(.green), .green, "Green"), (.color(.blue), .blue, "Blue"), (.color(.purple), .purple, "Purple"),
    ]

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 14) {
                item(isOn: criteria.rating == .rejected, label: "Rejected") {
                    Image(systemName: "xmark.circle")
                        .symbolVariant(criteria.rating == .rejected ? .fill : .none)
                        .foregroundStyle(criteria.rating == .rejected ? Color.red : .secondary)
                } action: { choose(rating: .rejected) }
                ForEach(1...5, id: \.self) { n in
                    let lit = starIsLit(n)
                    item(isOn: lit, label: n == 1 ? "1 star" : "\(n) stars") {
                        Image(systemName: lit ? "star.fill" : "star").foregroundStyle(lit ? Color.yellow : .secondary)
                    } action: { chooseStars(n, NSEvent.modifierFlags) }
                }
            }
            HStack(spacing: 14) {
                ForEach(Self.labels.indices, id: \.self) { i in
                    let (label, color, name) = Self.labels[i]
                    let on = criteria.label == label
                    item(isOn: on, label: "\(name) label") {
                        Circle().strokeBorder(color.map(Self.swatch) ?? .secondary, lineWidth: 2)
                            .background(Circle().fill(on ? (color.map(Self.swatch) ?? .secondary) : .clear))
                            .frame(width: 18, height: 18)
                    } action: { choose(label: label) }
                }
            }
            Text(criteria.isEmpty ? "Choose a rating or a label" : criteria.summary.prefix(1).uppercased() + criteria.summary.dropFirst())
                .font(.caption).foregroundStyle(.secondary)
        }
        .font(.system(size: 18))
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onAppear { focused = true }
        .onKeyPress(phases: .down) { press in key(press) }
    }

    private func item<Content: View>(isOn: Bool, label: String, @ViewBuilder content: () -> Content,
                                     action: @escaping () -> Void) -> some View {
        Button(action: action) { content().frame(width: 28, height: 28).contentShape(Rectangle()) }
            .buttonStyle(.plain)
            .accessibilityLabel(label)
            .accessibilityAddTraits(isOn ? .isSelected : [])
            .help(label)
    }

    private static func swatch(_ label: ColorLabel) -> Color {
        switch label {
        case .red: .red
        case .yellow: .yellow
        case .green: .green
        case .blue: .blue
        case .purple: .purple
        }
    }

    private func starIsLit(_ n: Int) -> Bool {
        switch criteria.rating {
        case .exactly(let m): n == m
        case .atLeast(let m): n >= m
        case .atMost(let m): n <= m
        default: false
        }
    }

    private func chooseStars(_ n: Int, _ flags: NSEvent.ModifierFlags) {
        choose(rating: flags.contains(.shift) ? .atMost(n) : flags.contains(.option) ? .atLeast(n) : .exactly(n))
    }

    /// A second choice of the same value clears the row.
    private func choose(rating: SelectionCriteria.Rating) {
        criteria.rating = criteria.rating == rating ? nil : rating
        apply(criteria)
    }

    private func choose(label: SelectionCriteria.Label) {
        criteria.label = criteria.label == label ? nil : label
        apply(criteria)
    }

    private func key(_ press: KeyPress) -> KeyPress.Result {
        let flags: NSEvent.ModifierFlags = [press.modifiers.contains(.shift) ? .shift : [], press.modifiers.contains(.option) ? .option : []]
        switch press.characters.lowercased() {
        case "1", "2", "3", "4", "5": chooseStars(Int(press.characters) ?? 1, flags)
        case "!", "@", "#", "$", "%":
            chooseStars(["!": 1, "@": 2, "#": 3, "$": 4, "%": 5][press.characters] ?? 1, .shift)
        case "0": choose(rating: .unrated)
        case "x": choose(rating: .rejected)
        case "6": choose(label: .color(.red))
        case "7": choose(label: .color(.yellow))
        case "8": choose(label: .color(.green))
        case "9": choose(label: .color(.blue))
        case "-": choose(label: .unlabeled)
        default:
            if press.key == .return { done(); return .handled }
            return .ignored
        }
        return .handled
    }
}
