import SwiftUI
import Observation

/// The HUD (D-12): a short glass sign that a command worked when nothing else on the screen changes. One shared
/// state, because the Loupe, Compare and app model all say things. It shows for `duration`, then goes. A new
/// phrase replaces the old one at once and restarts the timer; the timer is a single task, so after the HUD is
/// gone nothing runs (P-09).
@MainActor @Observable
final class HUD {
    static let shared = HUD()
    static let duration: Duration = .milliseconds(1200)

    /// What the HUD says now; nil when it is hidden. `serial` changes with every phrase, so the view can tell a
    /// replacement from a repeat.
    private(set) var phrase: String?
    private(set) var serial = 0
    @ObservationIgnored private var timer: Task<Void, Never>?

    func show(_ phrase: String) {
        self.phrase = phrase
        serial += 1
        timer?.cancel()
        timer = Task { [weak self] in
            try? await Task.sleep(for: Self.duration)
            guard !Task.isCancelled else { return }
            self?.phrase = nil
            self?.timer = nil
        }
    }
}

/// The capsule at the top center of the canvas. It never takes focus or a click, and VoiceOver skips it: the
/// same phrase is already announced. It appears with a cut and fades out; with Reduce Motion it cuts out too.
struct HUDView: View {
    let hud: HUD
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            if let phrase = hud.phrase {
                GlassEffectContainer {
                    Text(phrase)
                        .font(.callout)
                        .lineLimit(1)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .glassPlate()
                        .contrastProbe("hud", .glass, shape: .capsule, uses: [.text(.white)])
                }
                .id(hud.serial)
                .transition(.asymmetric(insertion: .identity, removal: reduceMotion ? .identity : .opacity))
            }
        }
        .padding(.top, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.3), value: hud.phrase == nil)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
