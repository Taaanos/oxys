import SwiftUI
import Observation

/// The HUD (D-12): a short glass sign that a command worked when nothing else on the screen changes. One shared
/// state, because the Loupe, Compare and app model all say things. It shows for `duration`, then goes. A new
/// phrase replaces the old one at once and restarts the timer; the timer is a single task, so after the HUD is
/// gone nothing runs (P-09).
@MainActor @Observable
final class HUD {
    struct Visible: Equatable {
        let phrase: String
        let serial: Int
    }

    private enum Display {
        case hidden
        case showing(Visible, Task<Void, Never>)
    }

    static let shared = HUD()
    static let duration: Duration = .milliseconds(1200)

    /// What the HUD says now, paired with its dismiss timer; hidden holds no phrase and no live timer.
    private var display: Display = .hidden
    @ObservationIgnored private var nextSerial = 0

    var visible: Visible? {
        if case .showing(let visible, _) = display { return visible }
        return nil
    }

    func show(_ phrase: String) {
        if case .showing(_, let timer) = display { timer.cancel() }
        nextSerial += 1
        let item = Visible(phrase: phrase, serial: nextSerial)
        let timer = Task { [weak self] in
            try? await Task.sleep(for: Self.duration)
            guard !Task.isCancelled else { return }
            self?.display = .hidden
        }
        display = .showing(item, timer)
    }
}

/// The capsule at the top center of the canvas. It never takes focus or a click, and VoiceOver skips it: the
/// same phrase is already announced. It appears with a cut and fades out; with Reduce Motion it cuts out too.
struct HUDView: View {
    let hud: HUD
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            if let visible = hud.visible {
                GlassEffectContainer {
                    Text(visible.phrase)
                        .font(.callout)
                        .lineLimit(1)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .glassPlate()
                        .contrastProbe("hud", .glass, shape: .capsule, uses: [.text(.white)])
                }
                .id(visible.serial)
                .transition(.asymmetric(insertion: .identity, removal: reduceMotion ? .identity : .opacity))
            }
        }
        .padding(.top, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.3), value: hud.visible == nil)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
