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

enum Plate {
    static let opacity = 0.7
    /// Secondary text on a plate. The system's secondary style is too dim over a bright photo; 85% white on
    /// the worst-case plate is about 6.7:1.
    static let secondary = Color.white.opacity(0.85)
}

extension Plate {
    /// Colored marks on a plate carry a word beside them, so the color is only a hint. Orange and a light red
    /// keep 3:1 on the worst-case plate, enough for a mark; the words stay white.
    static let warning = Color.orange
    static let reject = Color(red: 1, green: 0.42, blue: 0.40)
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
