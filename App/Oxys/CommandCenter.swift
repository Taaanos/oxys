import AppKit
import Commands
import Library
import Observation
import SwiftUI

/// Runs the command table: owns the keymap and router, installs the one key monitor, holds the handlers the
/// app registers, and answers the menu bar's questions (enabled? checked? which key?).
@MainActor @Observable
final class CommandCenter {
    typealias Handler = @MainActor (CommandPhase) -> Void

    /// `performAdvancing` is a cull key pressed with `⇧`: do it, then show the next photo.
    enum CommandPhase { case perform, performAdvancing, releaseHold }

    let table: CommandTable
    private(set) var keymap: Keymap
    /// What was wrong with the user's keymap file, if anything.
    private(set) var keymapProblems: [String]
    var mode: ViewMode = .loupe
    /// Offered every bare or `⌥` key first (M-18): code, shift, option. True when the inspector used the key.
    @ObservationIgnored var inspectorKey: (UInt16, Bool, Bool) -> Bool = { _, _, _ in false }
    /// Called for every key-down the window gets, held keys included (the film strip, V-20, waits for keys to stop).
    @ObservationIgnored var keyActivity: () -> Void = {}
    /// True while an in-window overlay (the cheat sheet) owns the keyboard; it gets every key but `⌘` chords.
    @ObservationIgnored var modalActive: () -> Bool = { false }
    /// Offered each key-down of a modal overlay.
    @ObservationIgnored var modalKey: (KeyInput) -> Void = { _ in }
    /// Set while Settings → Keys records a key (V-14). It gets every key-down, `⌘` chords and `Esc` included, and
    /// the monitor consumes the key-up too, so nothing reaches the menus or the photo.
    @ObservationIgnored var keyCapture: ((KeyInput) -> Void)?
    #if OXYS_DEV_HOOKS
    /// `KeysSelfTest` sends key events while another app may be in front, and macOS will not always give Oxys the
    /// focus. With this on, the monitor takes any window an event names as the key window. Bench build only.
    @ObservationIgnored var selfTestTakesAnyWindowAsKey = false
    #endif
    /// The Settings window. It is no place for cull keys, so the monitor does not route its keys (V-14).
    @ObservationIgnored weak var settingsWindow: NSWindow?
    /// Bumped when the input source changes, so menus re-read the key labels.
    private(set) var layoutRevision = 0

    @ObservationIgnored private let folder: FolderModel
    @ObservationIgnored private var router: KeyRouter
    @ObservationIgnored private var handlers: [CommandID: Handler] = [:]
    @ObservationIgnored private var states: [CommandID: @MainActor () -> Bool] = [:]
    @ObservationIgnored private var availability: [CommandID: @MainActor () -> Bool] = [:]
    @ObservationIgnored private var titles: [CommandID: @MainActor () -> String] = [:]
    @ObservationIgnored private var monitor: Any?
    @ObservationIgnored private var observers: [Any] = []

    /// The keymap comes from the `KeymapStore` (V-14), which reads `Keymap.json` and calls `applyKeymap` on every change.
    init(table: CommandTable = .standard, folder: FolderModel, keymap resolved: ResolvedKeymap) {
        self.table = table
        self.folder = folder
        keymap = resolved.keymap
        keymapProblems = resolved.problems
        var router = KeyRouter(keymap: resolved.keymap)
        if let t = UserDefaults.standard.object(forKey: "keyHoldThresholdSeconds") as? Double, t > 0 { router.holdThreshold = t }
        self.router = router
    }

    /// Runs on a new keymap: held keys are let go first, since the key that holds them may not mean the same now.
    /// Menus and the cheat sheet read `keymap`, so they change with it.
    func applyKeymap(_ resolved: ResolvedKeymap) {
        cancelHeldKeys()
        keymap = resolved.keymap
        keymapProblems = resolved.problems
        router.keymap = resolved.keymap
    }

    // MARK: registration

    /// Connects a command to its handler. `isOn` supplies the checkmark of a toggle, `isAvailable` an extra
    /// condition for enabling it (nothing to undo), `title` a menu title that follows state ("Undo Reject").
    func register(_ id: CommandID, isOn: (@MainActor () -> Bool)? = nil, isAvailable: (@MainActor () -> Bool)? = nil,
                  title: (@MainActor () -> String)? = nil, _ handler: @escaping Handler) {
        handlers[id] = handler
        states[id] = isOn
        availability[id] = isAvailable
        titles[id] = title
    }

    // MARK: menu bar

    var context: CommandContext { CommandContext(mode: mode, hasPhotos: folder.content == .photos) }

    func isEnabled(_ command: Command) -> Bool {
        handlers[command.id] != nil && command.isEnabled(in: context) && (availability[command.id]?() ?? true)
    }

    func title(for command: Command) -> String { titles[command.id]?() ?? command.title }

    func isOn(_ command: Command) -> Bool { states[command.id]?() ?? false }

    func perform(_ id: CommandID, phase: CommandPhase = .perform) {
        guard let command = table[id], isEnabled(command) else { return }
        handlers[id]?(phase)
    }

    /// The command's first key as the menus print it ("⌥⌘I"); empty when it has none. For hints and tooltips, so
    /// they follow the user's keys (V-14).
    func keyText(_ id: CommandID) -> String {
        _ = layoutRevision
        guard let first = keymap.shortcuts(for: id).first else { return "" }
        return KeyLabels.label(for: first)
    }

    /// "the ⌥⌘I key" for a sentence in Settings, or `menu` (where to find the command) when it has no key.
    func keyPhrase(_ id: CommandID, menu: String) -> String {
        let text = keyText(id)
        return text.isEmpty ? menu : "the \(text) key"
    }

    /// " (⌥⌘I)" for a tooltip, or nothing when the command has no key.
    func hint(_ id: CommandID) -> String {
        let text = keyText(id)
        return text.isEmpty ? "" : " (\(text))"
    }

    /// The command's first key as a menu equivalent, printed as the current layout labels it.
    func shortcut(for command: Command) -> KeyboardShortcut? {
        _ = layoutRevision
        guard let first = keymap.shortcuts(for: command.id).first,
              let key = Self.keyEquivalent(for: first.key) else { return nil }
        var mods: EventModifiers = []
        if first.modifiers.contains(.shift) { mods.insert(.shift) }
        if first.modifiers.contains(.control) { mods.insert(.control) }
        if first.modifiers.contains(.option) { mods.insert(.option) }
        if first.modifiers.contains(.command) { mods.insert(.command) }
        return KeyboardShortcut(key, modifiers: mods)
    }

    private static func keyEquivalent(for spec: KeySpec) -> KeyEquivalent? {
        if case .position(let key) = spec {
            switch key {
            case .leftArrow: return .leftArrow
            case .rightArrow: return .rightArrow
            case .upArrow: return .upArrow
            case .downArrow: return .downArrow
            case .home: return .home
            case .end: return .end
            case .space: return .space
            case .escape: return .escape
            case .return: return .return
            case .tab: return .tab
            case .delete: return .delete
            case .forwardDelete: return .deleteForward
            case .pageUp: return .pageUp
            case .pageDown: return .pageDown
            case .f1, .f2, .f3, .f4, .f5, .f6, .f7, .f8, .f9, .f10, .f11, .f12:
                // AppKit's function-key characters (`NSF1FunctionKey` and on) are 0xF704 to 0xF70F.
                let order: [PhysicalKey] = [.f1, .f2, .f3, .f4, .f5, .f6, .f7, .f8, .f9, .f10, .f11, .f12]
                guard let n = order.firstIndex(of: key), let scalar = Unicode.Scalar(0xF704 + UInt32(n)) else { return nil }
                return KeyEquivalent(Character(scalar))
            default: break
            }
        }
        // A label longer than one character ("Keypad 3") names no key a menu can show.
        let label = KeyLabels.label(for: spec)
        guard label.count == 1, let c = label.lowercased().first else { return nil }
        return KeyEquivalent(c)
    }

    // MARK: keys

    func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
            // Local monitors run on the main thread, but the closure type is not isolated.
            nonisolated(unsafe) let event = event
            let consumed = MainActor.assumeIsolated { self?.route(event) == true }
            return consumed ? nil : event
        }
        let center = NotificationCenter.default
        for name in [NSWindow.didResignKeyNotification, NSApplication.didResignActiveNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.cancelHeldKeys() }
            })
        }
        // Menus show keys as the current layout prints them, so they follow an input-source change.
        observers.append(DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.apple.Carbon.TISNotifySelectedKeyboardInputSourceChanged"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.layoutRevision += 1 }
        })
    }

    private func route(_ event: NSEvent) -> Bool {
        // Panels (Open, alerts) own their keys; so does anything while the window is not key.
        guard let window = event.window, isKey(window), !(window is NSPanel), window.sheetParent == nil,
              let input = KeyInput(event: event, layout: KeyLayout.asciiCapable())
        else { return false }
        // Settings → Keys is recording: it takes every key and nothing else sees it. The key-up of the Space that
        // pressed the Record button also ends here.
        if let capture = keyCapture {
            if event.type == .keyDown, !event.isARepeat { capture(input) }
            return true
        }
        // Settings is no place for cull keys. A key the keymap owns does nothing there, unless a field or control has it;
        // `⌘` chords go on, so `⌘W` and `⌘,` work as in any window.
        if window === settingsWindow {
            return !event.modifierFlags.contains(.command) && !(window.firstResponder is NSControl)
                && !((window.firstResponder as? NSTextView)?.isEditable == true)
                && keymap.command(for: input, mode: mode) != nil
        }
        if event.type == .keyDown { keyActivity() }
        if modalActive(), !event.modifierFlags.contains(.command) {
            if event.type == .keyDown { modalKey(input) }
            return true
        }
        // With Full Keyboard Access on, `⇥` and `⇧⇥` are how the keyboard moves between controls (the filter bar,
        // the toolbar, the banner's buttons), so they go to the system. "Focus Mode" stays in the View menu; Compare's `⌥⇥` still reaches the app.
        if NSApp.isFullKeyboardAccessEnabled, event.keyCode == PhysicalKey.tab.rawValue,
           event.modifierFlags.isDisjoint(with: [.command, .control, .option]) { return false }
        // A text field or a focused control (button, picker) owns its keys: Space presses a button, arrows move a
        // picker. `Esc` hands focus back to the image.
        let responder = window.firstResponder
        let focus: KeyFocus = if let tv = responder as? NSTextView, tv.isEditable || tv.isFieldEditor {
            .textInput
        } else if responder is NSControl {
            .textInput
        } else { .canvas }
        if event.type == .keyDown, focus == .canvas,
           event.modifierFlags.isDisjoint(with: [.command, .control]),
           inspectorKey(event.keyCode, event.modifierFlags.contains(.shift), event.modifierFlags.contains(.option)) { return true }
        let result = router.handle(input, mode: mode, focus: focus)
        apply(result.actions)
        return result.consumed
    }

    private func isKey(_ window: NSWindow) -> Bool {
        #if OXYS_DEV_HOOKS
        if selfTestTakesAnyWindowAsKey { return true }
        #endif
        return window.isKeyWindow
    }

    private func apply(_ actions: [RoutedAction]) {
        for action in actions {
            switch action {
            case .perform(let id): perform(id, phase: .perform)
            case .performAdvancing(let id): perform(id, phase: .performAdvancing)
            case .releaseHold(let id): perform(id, phase: .releaseHold)
            case .returnFocusToCanvas: NSApp.keyWindow?.makeFirstResponder(nil)
            }
        }
    }

    private func cancelHeldKeys() {
        apply(router.cancelAll(at: ProcessInfo.processInfo.systemUptime))
    }
}

extension String {
    /// The first letter in capitals, for a phrase that starts a sentence.
    var sentenceCased: String { prefix(1).uppercased() + dropFirst() }
}
