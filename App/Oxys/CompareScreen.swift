import Canvas
import Library
import Metadata
import SwiftUI

/// Compare (V-08): the select on the left, the candidate on the right, a ring on the active side. Each pane has its
/// own truth badge, decision and info; the cull keys reach the active one. Zoom, pan and the overlays reach both (V-09).
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
        // Anchor for the `⌥H` popover: the bottom of the window, between the panes.
        .overlay(alignment: .bottom) {
            Color.clear.frame(width: 1, height: 1)
                .padding(.bottom, 34)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
                .popover(isPresented: Bindable(model.loupe).showClippingPopover, arrowEdge: .top) {
                    ClippingThresholdsPopover { model.loupe.showClippingPopover = false }
                }
        }
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
            CompareCanvas(pane: pane) { model.compare.activate(pane.side) }
            if let failure = pane.failure {
                ErrorTile(name: pane.shown?.name ?? "", message: failure)
            }
            if pane.truthBadge != nil || model.autoAdvance { TruthBadgeView(badge: pane.truthBadge, autoAdvance: model.autoAdvance, stripVisible: loupe.showInfoStrip) }
            if let photo = pane.shown, pane.failure == nil {
                if let peaking = loupe.peakingLabel(for: photo, developed: pane.developState == .raw) { PeakingBadgeView(label: peaking) }
                if let clipping = loupe.clippingLabel(for: photo, developed: pane.developState == .raw, stats: pane.clippingStats) {
                    ClippingReadout(label: clipping)
                }
            }
            PaneTitle(side: pane.side, active: active)
            if loupe.showInfoStrip {
                InfoStrip(photo: pane.shown, decision: pane.shown.flatMap { folder.decision(for: $0.url) }, zoom: pane.zoomInfo,
                          truth: pane.truthBadge,
                          exifFields: loupe.showExif ? pane.exif?.compareFields(against: compare.pane(pane.side.other).exif) ?? [] : [],
                          pulse: compare.cullPulse[pane.side] ?? 0)
            } else if loupe.showRatingCorner, let photo = pane.shown {
                RatingCorner(decision: folder.decision(for: photo.url) ?? Decision(), pulse: compare.cullPulse[pane.side] ?? 0)
            }
        }
        .background(Color(white: LoupeView.canvasGray))
        .clipShape(RoundedRectangle(cornerRadius: 4))
        // The ring marks the active pane. VoiceOver hears "Active" as the pane's value.
        .overlay { RoundedRectangle(cornerRadius: 4).strokeBorder(active ? Color.accentColor : .clear, lineWidth: 4).allowsHitTesting(false) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(pane.side.title)
        .accessibilityValue(active ? "Active" : "")
    }
}

/// "Select" or "Candidate" at the top left of a pane; the filled dot is on the pane the cull keys reach.
private struct PaneTitle: View {
    let side: ComparePair.Side
    let active: Bool

    var body: some View {
        Label {
            Text(side.title).foregroundStyle(.white)
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
    let onClick: @MainActor () -> Void

    func makeNSView(context: Context) -> LoupeView {
        let view = LoupeView()
        pane.canvas = view
        view.onClick = onClick
        return view
    }

    func updateNSView(_ view: LoupeView, context: Context) { view.onClick = onClick }
}
