import Canvas
import Imaging
import Library
import Metadata
import SwiftUI

/// Loupe: the canvas, an info strip along the bottom, and an error tile for a file that cannot be previewed.
struct LoupeScreen: View {
    let model: AppModel
    /// False while Grid is in front; the screen stays in the hierarchy so its canvas lives on.
    let active: Bool

    var body: some View {
        let folder = model.folder
        let loupe = model.loupe
        ZStack(alignment: .bottom) {
            LoupeCanvas(controller: loupe)
            if let failure = loupe.failure {
                ErrorTile(name: loupe.shown?.name ?? "", message: failure)
            }
            if let badge = loupe.badge { CullBadge(badge: badge) }
            if loupe.truthBadge != nil || model.autoAdvance { TruthBadgeView(badge: loupe.truthBadge, autoAdvance: model.autoAdvance) }
            if let peaking = loupe.peakingLabel { PeakingBadgeView(label: peaking) }
            if let clipping = loupe.clippingLabel { ClippingReadout(label: clipping) }
            // Anchor for the `⌥H` popover: the corner where the readout sits.
            Color.clear.frame(width: 1, height: 1)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                .padding(.bottom, 34)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
                .popover(isPresented: Bindable(loupe).showClippingPopover, arrowEdge: .trailing) {
                    ClippingThresholdsPopover { loupe.showClippingPopover = false }
                }
            if loupe.showExif, let exif = loupe.exif, loupe.failure == nil {
                ExifPanel(info: exif, focused: Bindable(loupe).focusedExifField)
            }
            // The inspector has its own Histogram section, so the corner one steps aside while it is open.
            if loupe.showHistogram, loupe.showInfoStrip, !(model.showInspector && !model.chromeHidden), let histogram = loupe.histogram, loupe.failure == nil {
                HistogramView(histogram: histogram)
                    .padding(12)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            }
            if loupe.showInfoStrip {
                InfoStrip(photo: loupe.shown, decision: loupe.shown.flatMap { folder.decision(for: $0.url) }, zoom: loupe.zoomInfo, truth: loupe.truthBadge)
            }
        }
        .background(Color(white: LoupeView.canvasGray))
        .task(id: LoadKey(url: folder.currentURL, active: active)) {
            loupe.setActive(active)
            if active { await loupe.load(folder.currentPhoto, in: folder) }
        }
        .onChange(of: folder.folder) { loupe.reset() }
    }
}

private struct LoadKey: Equatable {
    let url: URL?
    let active: Bool
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

/// The EXIF values at the top left on a backing plate. A click or `↑`/`↓` focuses a value; `⌘C` copies it.
private struct ExifPanel: View {
    let info: ExifInfo
    @Binding var focused: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(info.fields) { field in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(field.label).foregroundStyle(Plate.secondary).frame(width: 110, alignment: .leading)
                    Text(field.value).textSelection(.enabled)
                }
                .font(.callout.monospacedDigit())
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
                .background(focused == field.label ? Color.accentColor.opacity(0.6) : .clear, in: RoundedRectangle(cornerRadius: 4))
                .contentShape(Rectangle())
                .onTapGesture { focused = focused == field.label ? nil : field.label }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(field.label), \(field.value)")
                .accessibilityAddTraits(focused == field.label ? .isSelected : [])
            }
        }
        .padding(10)
        .infoPlate()
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// Filename, the decision (stars, label, reject) and the size of the preview shown.
struct InfoStrip: View {
    let photo: Photo?
    let decision: Decision?
    let zoom: ZoomInfo?
    let truth: TruthBadge?
    /// Compare (V-08, V-09): shutter, aperture, ISO and focal length, short enough for half a window, and any other
    /// setting that differs from the other pane's photo. A differing value is marked.
    var exifFields: [CompareField] = []

    private var exifSpoken: String? {
        exifFields.isEmpty ? nil : exifFields.map { $0.differs ? "\($0.label) \($0.value), differs" : $0.value }.joined(separator: ", ")
    }

    private var zoomSpoken: String {
        guard let zoom else { return "" }
        return (zoom.level.isFit ? ", fit, \(zoom.percent) percent" : zoom.isActualSize ? ", actual size" : ", zoom \(zoom.percent) percent")
            + (truth.map { ", " + $0.spoken } ?? "")
    }

    var body: some View {
        if let photo {
            HStack(spacing: 12) {
                Text(photo.name).font(.callout.monospaced())
                if let companion = photo.companion {
                    Text("RAW+JPEG").font(.caption.weight(.semibold)).foregroundStyle(Plate.secondary)
                        .help("\(photo.name) and \(companion.url.lastPathComponent) are one frame; the decision goes to both")
                }
                if let decision, !decision.isUndecided { DecisionGlyphs(decision: decision) }
                if let note = photo.sidecar.notes.first {
                    PlateLabel(text: note, systemImage: photo.sidecar.problem == nil ? "info.circle" : "exclamationmark.triangle.fill",
                               tint: photo.sidecar.problem == nil ? Plate.secondary : Plate.warning)
                        .lineLimit(1)
                        .help(photo.sidecar.notes.joined(separator: "\n"))
                }
                if !exifFields.isEmpty { CompareExifLine(fields: exifFields) }
                if let zoom {
                    Text(zoom.level.isFit ? "Fit \(zoom.percent)%" : zoom.isActualSize ? "1:1" : "\(zoom.percent)%").foregroundStyle(Plate.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity)
            .background(.black.opacity(Plate.opacity))
            .foregroundStyle(.white)
            .environment(\.colorScheme, .dark)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(([photo.name, photo.isPair ? "RAW and JPEG" : nil, decision?.summary].compactMap { $0 } + photo.sidecar.notes).joined(separator: ", ") + (exifSpoken.map { ", " + $0 } ?? "") + zoomSpoken)
        }
    }
}

/// Stars, reject mark and label as text: a letter inside a distinct shape, never color alone.
struct DecisionGlyphs: View {
    let decision: Decision

    var body: some View {
        HStack(spacing: 8) {
            if decision.isReject {
                PlateLabel(text: "Rejected", systemImage: "xmark.circle.fill", tint: Plate.reject)
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

/// A colored rounded square carrying the label's letter. Black on all five colors is at least 5:1; white fails on green and red.
private struct LabelChip: View {
    let label: ColorLabel

    var body: some View {
        Text(String(label.letter))
            .font(.caption.bold().monospaced())
            .foregroundStyle(.black)
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
struct CullBadge: View {
    let badge: LoupeController.Badge

    var body: some View {
        VStack(spacing: 6) {
            DecisionGlyphs(decision: badge.decision)
                .font(.title2)
                .opacity(badge.decision.isUndecided ? 0 : 1)
            if badge.decision.isUndecided { Text("No rating").font(.title2) }
            if let name = badge.photoName { Text(name).font(.caption.monospaced()).foregroundStyle(Plate.secondary) }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .infoPlate(cornerRadius: 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// What a file that cannot be previewed shows: its name and why, never a crash or a blank frame.
struct ErrorTile: View {
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

/// The EXIF values of one Compare pane. A value that differs from the other photo's is bold, underlined and
/// named, and in the warning tint: it never rests on color alone.
private struct CompareExifLine: View {
    let fields: [CompareField]

    var body: some View {
        HStack(spacing: 10) {
            ForEach(fields) { field in
                if field.differs {
                    Text(field.value.hasPrefix(field.label) ? field.value : "\(field.label) \(field.value)").bold().underline().foregroundStyle(Plate.warning)
                } else {
                    Text(field.value).foregroundStyle(Plate.secondary)
                }
            }
        }
        .lineLimit(1)
    }
}
