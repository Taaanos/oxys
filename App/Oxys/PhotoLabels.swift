import SwiftUI

/// The labels that float over the bottom corners of a photo (D-02): the left stack (clipping, peaking, rating corner)
/// and the right stack (truth badge, auto-advance). Each stack is one `GlassEffectContainer`, so the system draws its
/// glass in one pass. The stacks sit above the info strip in a column with it, so no label needs a fixed offset and
/// they follow the strip's height. The labels never take clicks.
struct PhotoLabels<Left: View, Right: View>: View {
    @ViewBuilder let left: Left
    @ViewBuilder let right: Right

    var body: some View {
        HStack(alignment: .bottom) {
            GlassEffectContainer { VStack(alignment: .leading, spacing: 6) { left } }
            Spacer(minLength: 0)
            GlassEffectContainer { VStack(alignment: .trailing, spacing: 6) { right } }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .allowsHitTesting(false)
    }
}
