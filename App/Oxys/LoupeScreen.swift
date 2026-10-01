import Canvas
import Library
import SwiftUI

/// Loupe: the canvas, an info strip along the bottom, and an error tile for a file that cannot be previewed.
struct LoupeScreen: View {
    let model: AppModel

    var body: some View {
        let folder = model.folder
        let loupe = model.loupe
        ZStack(alignment: .bottom) {
            LoupeCanvas(controller: loupe)
            if let failure = loupe.failure {
                ErrorTile(name: loupe.shown?.name ?? "", message: failure)
            }
            if let badge = loupe.badge { CullBadge(badge: badge) }
            InfoStrip(photo: loupe.shown, decision: loupe.shown.flatMap { folder.decision(for: $0.url) }, pixels: loupe.shownPixels)
        }
        .background(Color(white: LoupeView.canvasGray))
        .task(id: folder.currentURL) { await loupe.load(folder.currentPhoto, in: folder) }
        .onChange(of: folder.folder) { loupe.reset() }
    }
}

private struct LoupeCanvas: NSViewRepresentable {
    let controller: LoupeController

    func makeNSView(context: Context) -> LoupeView {
        let view = LoupeView()
        controller.canvas = view
        return view
    }

    func updateNSView(_ view: LoupeView, context: Context) {}
}

/// Filename, the decision (stars, label, reject) and the size of the preview shown.
private struct InfoStrip: View {
    let photo: Photo?
    let decision: Decision?
    let pixels: (width: Int, height: Int)?

    var body: some View {
        if let photo {
            HStack(spacing: 12) {
                Text(photo.name).font(.callout.monospaced())
                if let decision, !decision.isUndecided { DecisionGlyphs(decision: decision) }
                if let pixels {
                    Text("Preview \(max(pixels.width, pixels.height)) px").foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity)
            .background(.black.opacity(0.45))
            .environment(\.colorScheme, .dark)
            .accessibilityElement(children: .combine)
            .accessibilityLabel([photo.name, decision?.summary].compactMap { $0 }.joined(separator: ", "))
        }
    }
}

/// Stars, reject mark and label as text: a letter inside a distinct shape, never color alone.
private struct DecisionGlyphs: View {
    let decision: Decision

    var body: some View {
        HStack(spacing: 8) {
            if decision.isReject {
                Label("Rejected", systemImage: "xmark.circle.fill").foregroundStyle(.red)
            } else if decision.stars > 0 {
                Text(String(repeating: "★", count: decision.stars) + String(repeating: "☆", count: 5 - decision.stars))
                    .foregroundStyle(.yellow)
            }
            if let label = decision.label { LabelChip(label: label) }
        }
        .font(.callout)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(decision.summary)
    }
}

/// A colored rounded square carrying the label's letter.
private struct LabelChip: View {
    let label: ColorLabel

    var body: some View {
        Text(String(label.letter))
            .font(.caption.bold().monospaced())
            .foregroundStyle(label == .yellow ? .black : .white)
            .frame(width: 18, height: 18)
            .background(label.color, in: RoundedRectangle(cornerRadius: 4))
    }
}

private extension ColorLabel {
    var color: Color {
        switch self {
        case .red: .red
        case .yellow: .yellow
        case .green: .green
        case .blue: .blue
        case .purple: .purple
        }
    }
}

/// The confirmation after a cull key. It is a cut, not an animation, and VoiceOver hears the same phrase
/// through the controller's announcement, so the badge itself is hidden from it.
private struct CullBadge: View {
    let badge: LoupeController.Badge

    var body: some View {
        VStack(spacing: 6) {
            DecisionGlyphs(decision: badge.decision)
                .font(.title2)
                .opacity(badge.decision.isUndecided ? 0 : 1)
            if badge.decision.isUndecided { Text("No rating").font(.title2) }
            if let name = badge.photoName { Text(name).font(.caption.monospaced()).foregroundStyle(.secondary) }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 10))
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// What a file that cannot be previewed shows: its name and why, never a crash or a blank frame.
private struct ErrorTile: View {
    let name: String
    let message: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
                .font(.largeTitle)
            Text(name).font(.title3.monospaced())
            Text(message)
        }
        .foregroundStyle(.white.opacity(0.7))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(name). \(message)")
    }
}
