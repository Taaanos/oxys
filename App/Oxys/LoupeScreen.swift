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
            if loupe.showExif, let exif = loupe.exif, loupe.failure == nil {
                ExifPanel(info: exif, focused: Bindable(loupe).focusedExifField)
            }
            // The inspector has its own Histogram section, so the corner one steps aside while it is open.
            if loupe.showHistogram, loupe.showInfoStrip, !(model.showInspector && !model.chromeHidden), let histogram = loupe.histogram, loupe.failure == nil {
                HistogramView(histogram: histogram, onPhoto: true)
                    .padding(12)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            }
            // The labels sit above the strip in one column, so they follow its height.
            VStack(spacing: 0) {
                PhotoLabels {
                    if let clipping = loupe.clippingLabel { ClippingReadout(label: clipping) }
                    if let peaking = loupe.peakingLabel { PeakingBadgeView(label: peaking) }
                    if !loupe.showInfoStrip, loupe.showRatingCorner, let photo = loupe.shown {
                        RatingCorner(decision: folder.decision(for: photo.url) ?? Decision(), pulse: loupe.cullPulse)
                    }
                } right: {
                    if let badge = loupe.truthBadge, !loupe.showInfoStrip { TruthBadgeView(badge: badge) }
                    if model.autoAdvance { AutoAdvanceBadge() }
                }
                // Anchor for the `⌥H` popover: the corner where the readout sits.
                .background(alignment: .bottomLeading) {
                    Color.clear.frame(width: 1, height: 1)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                        .popover(isPresented: Bindable(loupe).showClippingPopover, arrowEdge: .trailing) {
                            ClippingThresholdsPopover { loupe.showClippingPopover = false }
                        }
                }
                if loupe.showInfoStrip {
                    InfoStrip(photo: loupe.shown, decision: loupe.shown.flatMap { folder.decision(for: $0.url) }, zoom: loupe.zoomInfo, truth: loupe.truthBadge,
                              pulse: loupe.cullPulse)
                }
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
        .probeContent()
        .padding(10)
        .glassPlate(in: .rect(cornerRadius: 12))
        .contrastProbe("exif-panel", .glass, shape: .rounded(12), uses: [.text(.white), .text(.secondary)])
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
    /// Changes when a cull key took effect; the rating glyphs bounce.
    var pulse = 0

    /// D-11 spike: `defaults write <bundle id> OxysInfoStripStyle glass` draws the strip as a floating glass bar; `glass-split` as two capsules, the photo's state at the left and the truth badge at the right.
    static var style: InfoStripStyle {
        switch UserDefaults.standard.string(forKey: "OxysInfoStripStyle") {
        case "glass": .glass
        case "glass-split": .split
        default: .plate
        }
    }

    private var exifSpoken: String? {
        exifFields.isEmpty ? nil : exifFields.map { $0.differs ? "\($0.label) \($0.value), differs" : $0.value }.joined(separator: ", ")
    }

    private var zoomSpoken: String {
        guard let zoom else { return "" }
        return (zoom.level.isFit ? ", fit, \(zoom.percent) percent" : zoom.isActualSize ? ", actual size" : ", zoom \(zoom.percent) percent")
            + (truth.map { ", " + $0.spoken } ?? "")
    }

    @ViewBuilder private func state(_ photo: Photo, withDecision: Bool = true) -> some View {
        Text(photo.name).font(.callout.monospaced())
        if let companion = photo.companion {
            Text("RAW+JPEG").font(.caption.weight(.semibold)).foregroundStyle(Plate.secondary)
                .help("\(photo.name) and \(companion.url.lastPathComponent) are one frame; the decision goes to both")
        }
        if withDecision, let decision, !decision.isUndecided { DecisionGlyphs(decision: decision, pulse: pulse) }
        if let note = photo.sidecar.notes.first {
            PlateLabel(text: note, systemImage: photo.sidecar.problem == nil ? "info.circle" : "exclamationmark.triangle.fill",
                       tint: photo.sidecar.problem == nil ? Plate.secondary : Plate.warning)
                .lineLimit(1)
                .help(photo.sidecar.notes.joined(separator: "\n"))
        }
        if !exifFields.isEmpty { CompareExifLine(fields: exifFields) }
        if let zoom {
            Text(zoom.level.isFit ? "Fit \(zoom.percent)%" : zoom.isActualSize ? "1:1" : "\(zoom.percent)%").foregroundStyle(Plate.secondary)
                .monospacedDigit()
        }
    }

    private var uses: [ContrastProbe.Use] {
        // Compare's EXIF line draws a differing value as text in the warning tint; Loupe uses that tint only for icons.
        [.text(.white), .text(.secondary), .mark(.star), .mark(.reject), exifFields.isEmpty ? .mark(.warning) : .text(.warningText)]
    }

    private func spoken(_ photo: Photo) -> String {
        ([photo.name, photo.isPair ? "RAW and JPEG" : nil, decision?.summary].compactMap { $0 } + photo.sidecar.notes).joined(separator: ", ") + (exifSpoken.map { ", " + $0 } ?? "") + zoomSpoken
    }

    var body: some View {
        if let photo {
            if Self.style == .split {
                // The state capsule keeps the leading edge and the truth capsule the trailing edge, so only the inner edges move while `→` is held.
                GlassEffectContainer {
                    HStack(alignment: .bottom, spacing: 12) {
                        // The decision leads the capsule, with empty stars drawn and a slot as wide as five stars, so the filename keeps its place from frame to frame.
                        HStack(spacing: 12) {
                            ZStack(alignment: .leading) {
                                DecisionGlyphs(decision: Decision(rating: 5), showsEmptyStars: true).hidden()
                                DecisionGlyphs(decision: decision ?? Decision(), pulse: pulse, showsEmptyStars: true)
                            }
                            state(photo, withDecision: false)
                        }
                        .probeContent()
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .glassPlate()
                        .contrastProbe("info-strip", .glass, shape: .capsule, uses: uses)
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel(spoken(photo))
                        Spacer(minLength: 0)
                        if let truth {
                            TruthText(badge: truth)
                                .probeContent()
                                .padding(.horizontal, 12).padding(.vertical, 6)
                                .glassPlate()
                                .contrastProbe("info-strip-truth", .glass, shape: .capsule, uses: [.text(.secondary), .mark(.warning)])
                                .accessibilityHidden(true)
                        }
                    }
                }
                .padding(12)
            } else {
                HStack(spacing: 12) {
                    state(photo)
                    Spacer()
                    if let truth { TruthText(badge: truth) }
                }
                .probeContent()
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity)
                .modifier(StripBacking(style: Self.style, uses: uses))
                .accessibilityElement(children: .combine)
                .accessibilityLabel(spoken(photo))
            }
        }
    }
}

enum InfoStripStyle { case plate, glass, split }

/// The strip's backing. The plate is a full-width black band; the glass bar floats 12 pt in from the window edges (D-11).
private struct StripBacking: ViewModifier {
    let style: InfoStripStyle
    let uses: [ContrastProbe.Use]

    func body(content: Content) -> some View {
        switch style {
        case .plate:
            content
                .background(.black.opacity(Plate.opacity))
                .contrastProbe("info-strip", .plate, shape: .rect, uses: uses)
                .foregroundStyle(.white)
                .environment(\.colorScheme, .dark)
        case .glass, .split:
            content
                .glassPlate(in: .rect(cornerRadius: 12))
                .contrastProbe("info-strip", .glass, shape: .rounded(12), uses: uses)
                .padding(12)
        }
    }
}

/// The truth badge's words inside the info strip: the warning triangle stays, so a warning never rests on color.
private struct TruthText: View {
    let badge: TruthBadge

    var body: some View {
        if badge.isWarning {
            PlateLabel(text: badge.text, systemImage: "exclamationmark.triangle.fill", tint: Plate.warning).lineLimit(1)
        } else {
            Text(badge.text).foregroundStyle(Plate.secondary).lineLimit(1)
        }
    }
}

/// Stars, reject mark and label as shapes with a letter or a count, never color alone. When `pulse` changes (a cull
/// key took effect) the stars and the reject mark bounce and the label chip scales in, changes color or fades out: a cue at the edge of the frame,
/// where a change is noticed without reading. Reduce Motion turns the motion off.
struct DecisionGlyphs: View {
    let decision: Decision
    var pulse = 0
    /// Draw empty stars for an unrated photo, so the corner readout keeps its place.
    var showsEmptyStars = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let trigger = reduceMotion ? 0 : pulse
        HStack(spacing: 0) {
            if decision.isReject {
                PlateLabel(text: "Rejected", systemImage: "xmark.circle.fill", tint: Plate.reject)
                    .symbolEffect(.bounce, options: .nonRepeating, value: trigger)
            } else if decision.stars > 0 || showsEmptyStars {
                HStack(spacing: 1) {
                    ForEach(1...5, id: \.self) { star in
                        StarGlyph(index: star, filled: star <= decision.stars, isLast: star == decision.stars, pulse: trigger)
                    }
                }
            }
            LabelSlot(label: decision.label, pulse: trigger)
        }
        .font(.callout)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(decision.summary)
    }
}

/// One star. When a cull key lands (`pulse` changes), the new stars fill one after another, 30 ms apart: each
/// morphs from outline to filled (Magic Replace) and flashes, so the motion counts the stars. Only the last
/// filled star bounces, once, so the cue is one pulse and not one per star. Stars that did not change stay
/// still, and so does a key that did not touch the rating (a color label), and a change with no key behind it, such as moving to another photo. `pulse` stays 0 under
/// Reduce Motion, which makes every change instant.
private struct StarGlyph: View {
    let index: Int
    let filled: Bool
    let isLast: Bool
    let pulse: Int
    @State private var shown: Bool
    @State private var bounce = 0
    @State private var flash = 0
    /// True only while a cull key fills this star. Magic Replace runs on any symbol change, so without this flag
    /// walking from a 4-star photo to a 5-star one would animate the fifth star.
    @State private var morphs = false
    /// The delayed fill; a newer change cancels it so a fast `5` then `1` cannot fill a star late.
    @State private var pending: Task<Void, Never>?

    init(index: Int, filled: Bool, isLast: Bool, pulse: Int) {
        self.index = index
        self.filled = filled
        self.isLast = isLast
        self.pulse = pulse
        _shown = State(initialValue: filled)
    }

    private struct Key: Equatable { let filled: Bool; let isLast: Bool; let pulse: Int }

    var body: some View {
        Image(systemName: shown ? "star.fill" : "star")
            .foregroundStyle(shown ? Color.yellow : Plate.secondary)
            .contentTransition(morphs ? .symbolEffect(.replace) : .identity)
            .symbolEffect(.bounce, options: .nonRepeating, value: bounce)
            .phaseAnimator([0.0, 0.3, 0.0], trigger: flash) { star, glow in star.brightness(glow) } animation: { glow in
                glow == 0 ? .easeOut(duration: 0.2) : .easeOut(duration: 0.08)
            }
            .onChange(of: Key(filled: filled, isLast: isLast, pulse: pulse)) { old, new in
                pending?.cancel()
                // A key that left this star as it was (a label, say) must not animate it.
                guard new.pulse != old.pulse, new.filled, old.filled != new.filled || old.isLast != new.isLast else {
                    morphs = false
                    shown = new.filled
                    return
                }
                pending = Task {
                    try? await Task.sleep(for: .milliseconds(30 * (index - 1)))
                    guard !Task.isCancelled else { return }
                    if !shown {
                        morphs = true
                        withAnimation(.spring(duration: 0.3, bounce: 0.3)) { shown = true }
                        flash += 1
                    }
                    if isLast { bounce += 1 }
                }
            }
    }
}

/// The label chip. When a cull key changes the label (`pulse` changes with it) the chip scales in, cross-fades to the
/// new color with a short flash, or fades out. A key that left the label as it was (a rating) does nothing, and neither
/// does a change with no key behind it, such as moving to another photo. `pulse` stays 0 under Reduce Motion.
private struct LabelSlot: View {
    let label: ColorLabel?
    let pulse: Int
    @State private var shown: ColorLabel?
    @State private var flash = 0

    init(label: ColorLabel?, pulse: Int) {
        self.label = label
        self.pulse = pulse
        _shown = State(initialValue: label)
    }

    private struct Key: Equatable { let label: ColorLabel?; let pulse: Int }

    var body: some View {
        ZStack {
            if let shown {
                LabelChip(label: shown)
                    .padding(.leading, 8)
                    .phaseAnimator([0.0, 0.3, 0.0], trigger: flash) { chip, glow in chip.brightness(glow) } animation: { glow in
                        glow == 0 ? .easeOut(duration: 0.15) : .easeOut(duration: 0.06)
                    }
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
            }
        }
        .onChange(of: Key(label: label, pulse: pulse)) { old, new in
            guard new.pulse != old.pulse, new.label != old.label else {
                shown = new.label
                return
            }
            withAnimation(.spring(duration: 0.25, bounce: 0.3)) { shown = new.label }
            if new.label != nil { flash += 1 }
        }
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

/// `⌥I`: the photo's rating at the bottom-left, for when the info strip is off. It is the strip's rating mark
/// alone on a glass capsule (`glassPlate`), so culling with a bare window still shows what a key did; VoiceOver hears
/// the controller's announcement.
struct RatingCorner: View {
    let decision: Decision
    let pulse: Int

    var body: some View {
        DecisionGlyphs(decision: decision, pulse: pulse, showsEmptyStars: true)
            .probeContent()
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .glassPlate()
            .contrastProbe("rating-corner", .glass, shape: .capsule, uses: [.text(.secondary), .mark(.star), .mark(.reject)])
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
                    Text(field.value.hasPrefix(field.label) ? field.value : "\(field.label) \(field.value)").bold().underline().foregroundStyle(Plate.warningText)
                } else {
                    Text(field.value).foregroundStyle(Plate.secondary)
                }
            }
        }
        .lineLimit(1)
    }
}
