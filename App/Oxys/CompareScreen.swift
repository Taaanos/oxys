import Canvas
import Library
import Metadata
import SwiftUI

/// Compare (V-08): the select on the left, the candidate on the right, a ring on the active side. Each pane has its
/// own truth badge, decision and info; the cull keys reach the active one. Zoom, pan and the overlays reach both (V-09).
struct CompareScreen: View {
    let model: AppModel
    @State private var fullScreen = NSApp.keyWindow?.styleMask.contains(.fullScreen) == true

    var body: some View {
        let compare = model.compare
        // `ConcentricRectangle` does not find the window's curve on macOS 27, even with a `.containerShape` (D-08/Q1), so
        // the radii are set here. The window rounds at about 26 pt with a toolbar; a pane corner at a window corner takes that
        // less the 6 pt gap. The toolbar covers the top corners unless the chrome is hidden, the inspector covers the
        // trailing ones, and full screen is square: those corners keep the small radius.
        let outer = fullScreen ? Plate.paneRadius : max(Plate.paneRadius, Plate.windowRadius - 6)
        let top = model.chromeHidden ? outer : Plate.paneRadius
        let trailing = model.showInspector && !model.chromeHidden ? Plate.paneRadius : outer
        HStack(spacing: 6) {
            ComparePaneView(model: model, pane: compare.select, active: compare.pair?.active == .select,
                            shape: Plate.paneShape(topLeading: top, bottomLeading: outer, bottomTrailing: Plate.paneRadius, topTrailing: Plate.paneRadius))
            ComparePaneView(model: model, pane: compare.candidate, active: compare.pair?.active == .candidate,
                            shape: Plate.paneShape(topLeading: Plate.paneRadius, bottomLeading: Plate.paneRadius, bottomTrailing: trailing,
                                                   topTrailing: model.showInspector && !model.chromeHidden ? Plate.paneRadius : top))
        }
        .padding(6)
        .background(Color(white: LoupeView.canvasGray))
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didEnterFullScreenNotification)) { _ in fullScreen = true }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didExitFullScreenNotification)) { _ in fullScreen = false }
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
    let shape: UnevenRoundedRectangle

    var body: some View {
        let compare = model.compare
        let folder = model.folder
        let loupe = model.loupe
        ZStack(alignment: .bottom) {
            CompareCanvas(pane: pane) { model.compare.activate(pane.side) }
            if let failure = pane.failure {
                ErrorTile(name: pane.shown?.name ?? "", message: failure)
            }
            PaneTitle(side: pane.side, active: active)
            // The labels sit above the strip in one column, so they follow its height.
            VStack(spacing: 0) {
                PhotoLabels {
                    if let photo = pane.shown, pane.failure == nil {
                        if let clipping = loupe.clippingLabel(for: photo, developed: pane.developState == .raw, stats: pane.clippingStats) {
                            ClippingReadout(label: clipping)
                        }
                        if let peaking = loupe.peakingLabel(for: photo, developed: pane.developState == .raw) { PeakingBadgeView(label: peaking) }
                    }
                    if !loupe.showInfoStrip, loupe.showRatingCorner, let photo = pane.shown {
                        RatingCorner(decision: folder.decision(for: photo.url) ?? Decision(), pulse: compare.cullPulse[pane.side] ?? 0)
                    }
                } right: {
                    if let badge = pane.truthBadge, !loupe.showInfoStrip { TruthBadgeView(badge: badge) }
                    if model.autoAdvance { AutoAdvanceBadge() }
                }
                if loupe.showInfoStrip {
                    InfoStrip(photo: pane.shown, decision: pane.shown.flatMap { folder.decision(for: $0.url) }, zoom: pane.zoomInfo,
                              truth: pane.truthBadge,
                              exifFields: loupe.showExif ? pane.exif?.compareFields(against: compare.pane(pane.side.other).exif) ?? [] : [],
                              pulse: compare.cullPulse[pane.side] ?? 0)
                }
            }
        }
        .background(Color(white: LoupeView.canvasGray))
        .clipShape(shape)
        // The ring marks the active pane. VoiceOver hears "Active" as the pane's value. The contrast probe hides it for its
        // plate capture: it covers the strip's outer 4 pt, where no text sits.
        .overlay { shape.strokeBorder(active && !ContrastProbe.shared.blank ? Color.accentColor : .clear, lineWidth: 4).allowsHitTesting(false) }
        .environment(\.probeScope, pane.side == .select ? "select" : "candidate")
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
            Image(systemName: active ? "largecircle.fill.circle" : "circle").foregroundStyle(active ? Color.white : Plate.secondary)
        }
        .probeContent()
        .font(.callout.weight(.semibold))
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .glassPlate()
        .contrastProbe("pane-title", .glass, shape: .capsule, uses: [.text(.white), .mark(.secondary)])
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
