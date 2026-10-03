import AppKit
import Commands
import SwiftUI

/// F-05 throwaway window: shows which command each key fired, how it was matched, and whether the menu bar
/// also fired. Shown instead of the empty state when `OXYS_KEY_SPIKE=1`. Delete once M-05 lands the real router.
enum KeySpikeSetup {
    static var enabled: Bool { DevHooks.environment["OXYS_KEY_SPIKE"] == "1" }

    static let keymap: Keymap = {
        var b: [KeyBinding] = [
            .init(.position(.x), command: "cull.reject"),
            .init(.position(.x), [.shift], command: "cull.reject.advance"),
            .init(.position(.z), command: "view.zoom", behavior: .toggleOrHold),
            .init(.position(.f), command: "overlay.peaking", behavior: .toggleOrHold),
            .init(.position(.rightArrow), command: "nav.next", behavior: .repeating),
            .init(.position(.leftArrow), command: "nav.previous", behavior: .repeating),
            .init(.position(.escape), command: "nav.grid"),
            .init(.position(.a), [.command], command: "select.all"),
            .init(.position(.r), [.command], command: "file.reveal"),
            .init(.position(.z), [.command], command: "edit.undo"),
            .init(.character("["), command: "rate.down"),
            .init(.character("]"), command: "rate.up"),
            .init(.character("\\"), command: "cull.clear"),
            .init(.character("="), command: "zoom.in"),
            .init(.character("-"), command: "zoom.out"),
            .init(.character("?"), command: "help.cheatsheet"),
        ]
        let digits: [PhysicalKey] = [.digit1, .digit2, .digit3, .digit4, .digit5]
        for (i, k) in digits.enumerated() {
            b.append(.init(.position(k), command: CommandID(rawValue: "cull.rate\(i + 1)")))
            b.append(.init(.position(k), [.shift], command: CommandID(rawValue: "cull.rate\(i + 1).advance")))
        }
        return Keymap(b)
    }()
}

@MainActor @Observable
final class KeySpikeModel {
    var log: [String] = []
    /// Fires per command from the key router, and from the menu bar. A menu count that rises on a key press is a double fire.
    var routed: [String: Int] = [:]
    var menu: [String: Int] = [:]
    var zoomed = false
    var layoutName = ""
    @ObservationIgnored weak var canvas: NSView?
    @ObservationIgnored private var router = KeyRouter(keymap: KeySpikeSetup.keymap, holdThreshold: KeySpikeModel.holdThreshold)
    @ObservationIgnored private var monitor: Any?
    @ObservationIgnored private var resignObserver: Any?

    /// F-05/Q2: hidden default, 250 ms unless overridden.
    static var holdThreshold: Double {
        let v = UserDefaults.standard.double(forKey: "keyHoldThresholdSeconds")
        return v > 0 ? v : 0.25
    }

    func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
            // Local monitors run on the main thread, but the closure type is not isolated.
            nonisolated(unsafe) let event = event
            let consumed = MainActor.assumeIsolated { self?.route(event) == true }
            return consumed ? nil : event
        }
        resignObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                for a in self.router.cancelAll(at: ProcessInfo.processInfo.systemUptime) { self.apply(a, via: "focus lost") }
            }
        }
    }

    private func focus() -> KeyFocus {
        // The field editor is an NSTextView; so is any editable text view. IME marked text lives in these too.
        if let tv = NSApp.keyWindow?.firstResponder as? NSTextView, tv.isEditable || tv.isFieldEditor { return .textInput }
        return .canvas
    }

    /// Returns true when the event was consumed.
    private func route(_ event: NSEvent) -> Bool {
        let layout = KeyLayout.asciiCapable()
        layoutName = KeyLayout.current()?.sourceID ?? "?"
        guard let input = KeyInput(event: event, layout: layout) else { return false }
        let result = router.handle(input, mode: .loupe, focus: focus())
        for a in result.actions { apply(a, via: "key") }
        return result.consumed
    }

    func apply(_ action: RoutedAction, via source: String) {
        switch action {
        case .perform(let id):
            if id.rawValue == "view.zoom" { zoomed.toggle() }
            routed[id.rawValue, default: 0] += 1
            record("\(source): \(id.rawValue)\(id.rawValue == "view.zoom" ? " → \(zoomed ? "1:1" : "fit")" : "")")
        case .performAdvancing(let id):
            routed[id.rawValue, default: 0] += 1
            record("\(source): \(id.rawValue) + advance")
        case .releaseHold(let id):
            if id.rawValue == "view.zoom" { zoomed.toggle() }
            record("\(source): release \(id.rawValue)\(id.rawValue == "view.zoom" ? " → \(zoomed ? "1:1" : "fit")" : "")")
        case .returnFocusToCanvas:
            NSApp.keyWindow?.makeFirstResponder(canvas)
            record("\(source): focus → canvas")
        }
    }

    func menuFired(_ id: String) {
        menu[id, default: 0] += 1
        record("MENU: \(id)  ← double fire if this follows a key press")
    }

    private func record(_ line: String) {
        log.insert(line, at: 0)
        if log.count > 14 { log.removeLast() }
    }
}

struct KeySpikeView: View {
    @State private var model = KeySpikeModel()
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("F-05 key routing spike  ·  input source: \(model.layoutName)  ·  state: \(model.zoomed ? "1:1" : "fit")")
                .font(.headline)
            TextField("Type here: bare keys must not trigger commands. Esc returns to the canvas.", text: $text)
            KeyCanvas(model: model)
                .frame(height: 60)
                .overlay(Text("canvas (first responder)").foregroundStyle(.secondary))
            Text("Routed / menu counts").font(.subheadline)
            Text(model.routed.sorted { $0.key < $1.key }
                .map { "\($0.key)=\($0.value)\(model.menu[$0.key].map { "/menu \($0)" } ?? "")" }.joined(separator: "  "))
                .font(.system(.caption, design: .monospaced))
            Divider()
            ForEach(Array(model.log.enumerated()), id: \.offset) { _, line in
                Text(line).font(.system(.caption, design: .monospaced))
            }
            Spacer()
        }
        .padding()
        .onAppear { model.start() }
        .focusedSceneValue(\.keySpike, model)
    }
}

private struct KeyCanvas: NSViewRepresentable {
    let model: KeySpikeModel
    func makeNSView(context: Context) -> NSView {
        let v = SpikeCanvasView()
        model.canvas = v
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

private final class SpikeCanvasView: NSView {
    override var acceptsFirstResponder: Bool { true }
    override func viewDidMoveToWindow() { window?.makeFirstResponder(self) }
    override func keyDown(with event: NSEvent) { NSSound.beep() }  // an unrouted bare key reaches the view: audible in the spike
    override var focusRingMaskBounds: NSRect { bounds }
    override func drawFocusRingMask() { NSBezierPath(rect: bounds).fill() }
}

struct KeySpikeKey: FocusedValueKey { typealias Value = KeySpikeModel }
extension FocusedValues {
    var keySpike: KeySpikeModel? {
        get { self[KeySpikeKey.self] }
        set { self[KeySpikeKey.self] = newValue }
    }
}

/// Menu items carry the same shortcuts for display. If the router did not swallow the key, the item would fire too.
struct KeySpikeCommands: Commands {
    @FocusedValue(\.keySpike) var model

    var body: some Commands {
        CommandMenu("Spike") {
            item("Reject", "cull.reject", "x", [])
            item("Rate 3", "cull.rate3", "3", [])
            item("Rate 3 and advance", "cull.rate3.advance", "3", [.shift])
            item("Zoom 1:1", "view.zoom", "z", [])
            item("Next", "nav.next", .rightArrow, [])
            item("Select All", "select.all", "a", .command)
            item("Reveal", "file.reveal", "r", .command)
            item("Undo", "edit.undo", "z", .command)
            item("Rate down", "rate.down", "[", [])
            item("Cheat sheet", "help.cheatsheet", "?", [])
        }
    }

    private func item(_ title: String, _ id: String, _ key: KeyEquivalent, _ mods: EventModifiers) -> some View {
        Button(title) { model?.menuFired(id) }.keyboardShortcut(key, modifiers: mods)
    }
}
