import Canvas
import Library
import Metadata
import SwiftUI

/// Compare (V-08): the select on the left, the candidate on the right, a ring on the active side. Each pane has its
/// own truth badge, decision and info; the cull keys reach the active one.
struct CompareScreen: View {
    let model: AppModel

    var body: some View {
        let compare = model.compare
        HStack(spacing: 6) {
            ComparePaneView(model: model, pane: compare.select, active: compare.pair?.active == .select)
            ComparePaneView(model: model, pane: compare.candidate, active: compare.pair?.active == .candidate)
        }
        .padding(6)
        .background(Color(white: LoupeView.canvasGray))
        .onChange(of: model.folder.filter) { compare.listChanged() }
        .onChange(of: model.folder.photos.count) { compare.listChanged() }
        .onDisappear { compare.end() }
    }
}

private struct ComparePaneView: View {
    let model: AppModel
    let pane: ComparePane
    let active: Bool

    var body: some View {
        let compare = model.compare
        let folder = model.folder
        let loupe = model.loupe
        ZStack(alignment: .bottom) {
            CompareCanvas(pane: pane)
            if let failure = pane.failure {
                ErrorTile(name: pane.shown?.name ?? "", message: failure)
            }
            if let badge = compare.badge, badge.side == pane.side { CullBadge(badge: .init(id: badge.id, decision: badge.decision, photoName: badge.photoName)) }
            if let truth = pane.truthBadge { TruthBadgeView(badge: truth) }
            PaneTitle(side: pane.side, active: active)
            if loupe.showInfoStrip {
                InfoStrip(photo: pane.shown, decision: pane.shown.flatMap { folder.decision(for: $0.url) }, zoom: pane.zoomInfo,
                          truth: pane.truthBadge, exifLine: loupe.showExif ? pane.exif?.compactLine : nil)
            }
        }
        .background(Color(white: LoupeView.canvasGray))
        .clipShape(RoundedRectangle(cornerRadius: 4))
        // The ring. The title above says "active" in words, so the ring never rests on color alone.
        .overlay { RoundedRectangle(cornerRadius: 4).strokeBorder(active ? Color.accentColor : .clear, lineWidth: 4).allowsHitTesting(false) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(pane.side.title)
        .accessibilityValue(active ? "Active" : "")
    }
}

/// "Select" or "Candidate" at the top left of a pane, with "Active" on the pane the cull keys reach.
private struct PaneTitle: View {
    let side: ComparePair.Side
    let active: Bool

    var body: some View {
        Label {
            Text(active ? "\(side.title) · Active" : side.title).foregroundStyle(.white)
        } icon: {
            Image(systemName: active ? "largecircle.fill.circle" : "circle").foregroundStyle(active ? Color.accentColor : Plate.secondary)
        }
        .font(.callout.weight(.semibold))
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .infoPlate(cornerRadius: 8)
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private struct CompareCanvas: NSViewRepresentable {
    let pane: ComparePane

    func makeNSView(context: Context) -> LoupeView {
        let view = LoupeView()
        pane.canvas = view
        return view
    }

    func updateNSView(_ view: LoupeView, context: Context) {}
}

private extension ExifInfo {
    /// Focal length, aperture, shutter and ISO in one short line; what a photographer compares first.
    var compactLine: String? {
        let parts = [focalLength, aperture, shutter, iso].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: "  ")
    }
}
