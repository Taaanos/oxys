import SwiftUI

/// The backing plate under text drawn on a photo (M-18). Black at 70% leaves the plate no lighter than 30% gray
/// over a pure white photo, so white text keeps better than 4.5:1 on both bright and dark frames.
extension View {
    func infoPlate(cornerRadius: CGFloat = 8) -> some View {
        background(.black.opacity(Plate.opacity), in: RoundedRectangle(cornerRadius: cornerRadius))
            .foregroundStyle(.white)
            .environment(\.colorScheme, .dark)
    }
}

/// The glass behind a label on the photo (D-02): Liquid Glass tinted dark, so white text keeps its contrast over a
/// bright frame. Every label that floats on the photo goes through this one modifier, so the tint, the foreground
/// and the color scheme have one home. The label appears and disappears with a cut: its toggle is on the cull loop.
extension View {
    func glassPlate(in shape: some Shape = .capsule, transition: GlassEffectTransition = .identity) -> some View {
        foregroundStyle(.white)
            .environment(\.colorScheme, .dark)
            .glassEffect(.regular.tint(Plate.glassTint), in: shape)
            .glassEffectTransition(transition)
    }
}

enum Plate {
    /// The shape of a Compare pane and its ring (D-08). The small radius is for every corner that is not at a window corner.
    static let paneRadius: CGFloat = 4
    static func paneShape(topLeading: CGFloat, bottomLeading: CGFloat, bottomTrailing: CGFloat, topTrailing: CGFloat) -> UnevenRoundedRectangle {
        UnevenRoundedRectangle(topLeadingRadius: topLeading, bottomLeadingRadius: bottomLeading,
                               bottomTrailingRadius: bottomTrailing, topTrailingRadius: topTrailing)
    }
    /// The window's corner radius, which has no public API: about 26 pt for a window with a toolbar, measured from a screenshot.
    static let windowRadius: CGFloat = 26
    static let opacity = 0.7
    /// The one tint of every glass label (D-02/Q1), the share of black over the glass.
    static let glassOpacity = 0.5
    static var glassTint: Color { .black.opacity(glassOpacity) }
    /// Secondary text on a plate. The system's secondary style is too dim over a bright photo; 85% white on
    /// the worst-case plate is about 6.7:1.
    static let secondary = Color.white.opacity(0.85)
}

extension Plate {
    /// Colored marks on a plate carry a word beside them, so the color is only a hint. A light amber and a light red
    /// keep 3:1 on the worst-case plate, enough for a mark; the words stay white.
    static let warning = Color(red: 1, green: 0.68, blue: 0.20)
    static let reject = Color(red: 1, green: 0.62, blue: 0.60)
}

/// An icon in a color, then text in the plate's secondary white, so the text keeps 4.5:1.
struct PlateLabel: View {
    let text: String
    let systemImage: String
    let tint: Color

    var body: some View {
        Label {
            Text(text).foregroundStyle(Plate.secondary)
        } icon: {
            Image(systemName: systemImage).foregroundStyle(tint)
        }
    }
}
