import AppKit
import Canvas
import Commands
import Diagnostics
import Library
import SwiftUI

/// D-01: the contrast probe. With `OXYS_BENCH=contrast`, `OXYS_OPEN=<test frames>` and `OXYS_CONTRAST_DIR=<dir>` set,
/// the bench opens each test frame at 1:1 in Loupe and in Compare, turns on every label on the photo, and has
/// `scripts/contrast.sh` capture the window twice: once with the labels' text and symbols hidden (only the plate or the
/// glass is left, which `scripts/contrast-report.py` measures) and once as the user sees it. Each label reports its
/// frame in window points, its shape, its material and the colors drawn on it. Everything goes to the output folder,
/// never to the photo folder. Does nothing without `OXYS_CONTRAST_DIR`.
///
/// The handshake: the app writes `req-<n>.json` (window ID, image name), the script captures the window to that image,
/// the app waits for the file. At the end the app writes `probe.json` and `done`.
@MainActor @Observable
final class ContrastProbe {
    static let shared = ContrastProbe()
    nonisolated static let directory: URL? = ProcessInfo.processInfo.environment["OXYS_CONTRAST_DIR"].map { URL(fileURLWithPath: $0) }
    nonisolated static var enabled: Bool { directory != nil }

    /// True while the plate capture is taken: the labels hide their text and symbols, and keep their background.
    var blank = false
    @ObservationIgnored fileprivate var labels: [String: LabelRecord] = [:]

    // MARK: what a label reports

    enum Material: Encodable {
        case plate, glass
        var label: String {
            switch self {
            case .plate: "plate, black \(Int((Plate.opacity * 100).rounded()))%"
            case .glass: "glass, regular, black \(Int((Plate.glassOpacity * 100).rounded()))%"
            }
        }
        func encode(to encoder: any Encoder) throws {
            var c = encoder.singleValueContainer()
            try c.encode(label)
        }
    }

    enum Shape: Encodable {
        case rect, capsule, rounded(CGFloat)
        func encode(to encoder: any Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .rect: try c.encode("rect", forKey: .kind)
            case .capsule: try c.encode("capsule", forKey: .kind)
            case .rounded(let r): try c.encode("rounded", forKey: .kind); try c.encode(r, forKey: .radius)
            }
        }
        private enum CodingKeys: String, CodingKey { case kind, radius }
    }

    /// A color drawn on a plate. Text must keep 4.5:1 against the plate, a mark (an icon, a star) 3:1.
    enum Ink: String, CaseIterable, Encodable {
        case white, secondary, star, warning, reject, accent, cyan
        var color: Color {
            switch self {
            case .white: .white
            case .secondary: Plate.secondary
            case .star: .yellow
            case .warning: Plate.warning
            case .reject: Plate.reject
            case .accent: .accentColor
            case .cyan: .cyan
            }
        }
    }

    struct Use: Encodable {
        let ink: Ink
        let role: String
        static func text(_ ink: Ink) -> Use { Use(ink: ink, role: "text") }
        static func mark(_ ink: Ink) -> Use { Use(ink: ink, role: "mark") }
    }

    fileprivate struct LabelRecord {
        /// The view that reports it, so a view that goes away removes only its own record.
        let owner: UUID
        let scope: String
        let name: String
        let material: Material
        let shape: Shape
        let uses: [Use]
        var global: CGRect
    }

    fileprivate func set(_ record: LabelRecord) { labels["\(record.scope)/\(record.name)"] = record }
    fileprivate func remove(scope: String, name: String, owner: UUID) {
        if labels["\(scope)/\(name)"]?.owner == owner { labels["\(scope)/\(name)"] = nil }
    }
}

extension EnvironmentValues {
    /// Which canvas a label sits on, for the probe: `loupe`, the Compare pane (`select`, `candidate`), or `inspector`.
    @Entry var probeScope = "loupe"
}

extension View {
    /// The text and symbols of a label on the photo. Hidden while the probe captures the plate alone.
    func probeContent() -> some View { modifier(ProbeContent()) }

    /// Reports this label's plate to the probe: put it right after the plate or the glass, so the frame is the plate's.
    func contrastProbe(_ name: String, _ material: ContrastProbe.Material, shape: ContrastProbe.Shape, uses: [ContrastProbe.Use]) -> some View {
        modifier(ProbeFrame(name: name, material: material, shape: shape, uses: uses))
    }
}

private struct ProbeContent: ViewModifier {
    func body(content: Content) -> some View {
        if ContrastProbe.enabled { content.opacity(ContrastProbe.shared.blank ? 0 : 1) } else { content }
    }
}

private struct ProbeFrame: ViewModifier {
    let name: String
    let material: ContrastProbe.Material
    let shape: ContrastProbe.Shape
    let uses: [ContrastProbe.Use]
    @Environment(\.probeScope) private var scope
    @State private var owner = UUID()

    func body(content: Content) -> some View {
        if ContrastProbe.enabled {
            content
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { rect in
                    ContrastProbe.shared.set(.init(owner: owner, scope: scope, name: name, material: material, shape: shape, uses: uses, global: rect))
                }
                .onDisappear { ContrastProbe.shared.remove(scope: scope, name: name, owner: owner) }
        } else {
            content
        }
    }
}

// MARK: the bench scenario

extension ContrastProbe {
    private struct Capture: Encodable {
        let plate: String
        let text: String
        let mode: String
        let layout: String
        /// The label the split frame's edge was moved under; nil when the photos are centered.
        let edgeUnder: String?
        let labels: [LabelOut]
        /// Labels the layout should show but did not: the report fails them.
        let missing: [String]
    }

    private struct LabelOut: Encodable {
        let scope: String
        let name: String
        let photo: String
        /// x, y, width, height in window points, top-left origin, as the capture.
        let rect: [CGFloat]
        let material: String
        let shape: Shape
        let uses: [Use]
    }

    private struct Output: Encodable {
        var settings: [String: Bool] = [:]
        var appearance = ""
        var window: [String: CGFloat] = [:]
        var inks: [String: [Double]] = [:]
        var captures: [Capture] = []
    }

    private enum Layout: String {
        /// The info strip at its last level: name, EXIF panel (Loupe) and histogram (Loupe).
        case strip
        /// The strip off: the rating corner and the truth badge. The EXIF panel is a level of the strip, so it is off too.
        case bare
    }

    /// Labels a layout must show, per scope. Peaking, clipping and auto-advance are on throughout.
    private static func expected(_ layout: Layout, compare: Bool) -> [String] {
        let shared = ["peaking", "clipping", "auto-advance"] + (compare ? ["pane-title"] : [])
        switch layout {
        case .strip: return shared + ["info-strip"] + (compare ? [] : ["exif-panel", "histogram"])
        case .bare: return shared + ["rating-corner", "truth-badge"]
        }
    }

    static func run(_ model: AppModel) async {
        guard let directory else { Perf.record("contrast-no-dir", 1); return }
        let probe = shared
        let folder = model.folder, loupe = model.loupe, commands = model.commands, compare = model.compare
        // The view settings changed here are remembered by the app; `scripts/contrast.sh` puts the user's back afterwards.
        var out = Output()
        let workspace = NSWorkspace.shared
        out.settings = ["reduceTransparency": workspace.accessibilityDisplayShouldReduceTransparency,
                        "increaseContrast": workspace.accessibilityDisplayShouldIncreaseContrast,
                        "reduceMotion": workspace.accessibilityDisplayShouldReduceMotion]
        out.appearance = NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? "dark" : "light"
        // The labels set a dark color scheme, so their colors are the dark ones (high contrast when that is on).
        let dark = NSAppearance(named: workspace.accessibilityDisplayShouldIncreaseContrast ? .accessibilityHighContrastDarkAqua : .darkAqua)
        for ink in Ink.allCases {
            var rgba: [Double] = []
            (dark ?? NSApp.effectiveAppearance).performAsCurrentDrawingAppearance {
                if let c = NSColor(ink.color).usingColorSpace(.sRGB) {
                    rgba = [c.redComponent, c.greenComponent, c.blueComponent, c.alphaComponent].map(Double.init)
                }
            }
            out.inks[ink.rawValue] = rgba
        }

        LoupeView.paintsOverlays = false
        model.setInspector(false)
        model.autoAdvance = true
        if !loupe.showRatingCorner { loupe.toggleRatingCorner() }
        commands.perform("overlay.peaking"); commands.perform("overlay.highlights"); commands.perform("overlay.shadows")
        var count = 0

        func setLayout(_ layout: Layout) {
            let level: LoupeController.InfoLevel = layout == .strip ? .histogram : .off
            for _ in 0..<4 where loupe.infoLevel != level { loupe.cycleInfo() }
            if layout == .strip, !loupe.showHistogram { loupe.toggleHistogram() }
        }

        func window() -> NSWindow? { loupe.canvas?.window ?? NSApp.mainWindow }

        /// Converts SwiftUI's global frame (top-left of the content view) to window points, top-left origin.
        func windowRect(_ global: CGRect) -> [CGFloat] {
            guard let window = window(), let content = window.contentView else { return [] }
            let inWindow = content.convert(content.bounds, to: nil)
            return [global.minX + inWindow.minX, global.minY + window.frame.height - inWindow.maxY, global.width, global.height]
        }

        func shoot(_ image: String) async -> Bool {
            guard let window = window() else { return false }
            let target = directory.appending(path: image)
            let request = ["window": window.windowNumber, "image": image] as [String: Any]
            let data = (try? JSONSerialization.data(withJSONObject: request)) ?? Data()
            try? data.write(to: directory.appending(path: "req-\(count).json"), options: .atomic)
            count += 1
            let began = ContinuousClock.now
            while !FileManager.default.fileExists(atPath: target.path), began.duration(to: .now) < .seconds(15) {
                try? await Task.sleep(for: .milliseconds(20))
            }
            return FileManager.default.fileExists(atPath: target.path)
        }

        /// Both captures of the window as it is now. `photos` maps each scope on screen to the frame under it.
        func capture(mode: String, layout: Layout, photos: [String: String], edgeUnder: String? = nil) async {
            let names = expected(layout, compare: mode == "compare")
            let began = ContinuousClock.now
            func present() -> [LabelRecord] { probe.labels.values.filter { photos[$0.scope] != nil } }
            func missing() -> [String] {
                photos.keys.sorted().flatMap { scope in names.filter { name in !present().contains { $0.scope == scope && $0.name == name } }.map { "\(scope)/\($0)" } }
            }
            while !missing().isEmpty, began.duration(to: .now) < .seconds(5) { try? await Task.sleep(for: .milliseconds(50)) }
            // Glass adapts its look to what is under it with a short animation; let it finish.
            try? await Task.sleep(for: .milliseconds(700))
            let stem = String(format: "%03d", out.captures.count) + "-\(mode)-\(layout.rawValue)-" + photos.values.sorted().joined(separator: "+")
                + (edgeUnder.map { "-edge-\($0.replacingOccurrences(of: "/", with: "."))" } ?? "")
            probe.blank = true
            try? await Task.sleep(for: .milliseconds(300))
            let labels = present().sorted { ($0.scope, $0.name) < ($1.scope, $1.name) }.map {
                LabelOut(scope: $0.scope, name: $0.name, photo: photos[$0.scope] ?? "", rect: windowRect($0.global),
                         material: $0.material.label, shape: $0.shape, uses: $0.uses)
            }
            let plateOK = await shoot(stem + "-plate.png")
            probe.blank = false
            try? await Task.sleep(for: .milliseconds(300))
            let textOK = await shoot(stem + "-text.png")
            if !plateOK || !textOK { Perf.record("contrast-capture-timeout", 1) }
            out.captures.append(Capture(plate: stem + "-plate.png", text: stem + "-text.png", mode: mode, layout: layout.rawValue,
                                        edgeUnder: edgeUnder, labels: labels, missing: missing()))
        }

        /// The split frame: its black-and-white edge goes under each label off the middle of its canvas in turn.
        func edgeCaptures(mode: String, layout: Layout, photos: [String: String], canvas: (String) -> LoupeView?) async {
            for scope in photos.keys.sorted() where photos[scope] == "split" {
                guard let view = canvas(scope) else { continue }
                let inWindow = view.convert(view.bounds, to: nil)
                let middle = inWindow.midX
                let records = probe.labels.values.filter { $0.scope == scope }.sorted { $0.name < $1.name }
                for record in records {
                    let rect = windowRect(record.global)
                    guard rect.count == 4, !(rect[0]...(rect[0] + rect[2])).contains(middle) else { continue }
                    let dx = rect[0] + rect[2] / 2 - middle
                    view.pan(byPoints: CGPoint(x: dx, y: 0))
                    await capture(mode: mode, layout: layout, photos: photos, edgeUnder: "\(scope)/\(record.name)")
                    view.pan(byPoints: CGPoint(x: -dx, y: 0))
                }
            }
        }

        let photos = folder.visible
        // Loupe: each frame at 1:1, so it covers the whole canvas.
        for photo in photos {
            folder.setCurrent(photo.url)
            let began = ContinuousClock.now
            while loupe.shown?.url != photo.url || loupe.showingStandIn, began.duration(to: .now) < .seconds(10) { try? await Task.sleep(for: .milliseconds(20)) }
            commands.perform("zoom.actual")
            while !(loupe.zoomInfo?.isActualSize ?? false) || loupe.showingScreenSize, began.duration(to: .now) < .seconds(15) {
                try? await Task.sleep(for: .milliseconds(20))
            }
            let name = photo.url.deletingPathExtension().lastPathComponent
            for layout in [Layout.strip, .bare] {
                setLayout(layout)
                await capture(mode: "loupe", layout: layout, photos: ["loupe": name])
                await edgeCaptures(mode: "loupe", layout: layout, photos: ["loupe": name]) { _ in loupe.canvas }
            }
        }

        // Compare: each frame as the select and as the candidate, both at 1:1.
        for (i, photo) in photos.enumerated() {
            let other = photos[(i + 1) % photos.count]
            commands.perform("view.grid"); try? await Task.sleep(for: .milliseconds(300))
            folder.selectNone(); folder.click(photo.url, mode: .replace); folder.click(other.url, mode: .toggle)
            commands.perform("compare.enter")
            let began = ContinuousClock.now
            while compare.select.shown?.url != photo.url || compare.candidate.shown?.url != other.url, began.duration(to: .now) < .seconds(10) {
                try? await Task.sleep(for: .milliseconds(20))
            }
            commands.perform("zoom.actual")
            while ![compare.select, compare.candidate].allSatisfy({ $0.zoomInfo?.isActualSize ?? false }), began.duration(to: .now) < .seconds(15) {
                try? await Task.sleep(for: .milliseconds(20))
            }
            let names = ["select": photo.url.deletingPathExtension().lastPathComponent, "candidate": other.url.deletingPathExtension().lastPathComponent]
            for layout in [Layout.strip, .bare] {
                setLayout(layout)
                await capture(mode: "compare", layout: layout, photos: names)
                await edgeCaptures(mode: "compare", layout: layout, photos: names) { $0 == "select" ? compare.select.canvas : compare.candidate.canvas }
            }
        }
        commands.perform("view.grid")

        if let window = window() {
            out.window = ["width": window.frame.width, "height": window.frame.height, "scale": window.backingScaleFactor]
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? encoder.encode(out).write(to: directory.appending(path: "probe.json"), options: .atomic)
        try? Data().write(to: directory.appending(path: "done"))
        Perf.record("contrast-captures", Double(out.captures.count))
    }
}
