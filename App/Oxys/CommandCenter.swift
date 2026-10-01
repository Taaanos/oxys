import AppKit
import Commands
import Library
import Observation
import os
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
    @ObservationIgnored private static let log = Logger(subsystem: "dev.oxys.Oxys", category: "commands")

    /// `~/Library/Application Support/Oxys/Keymap.json` (M-05/Q1).
    static var userKeymapURL: URL {
        URL.applicationSupportDirectory.appending(path: "Oxys/Keymap.json", directoryHint: .notDirectory)
    }

    init(table: CommandTable = .standard, folder: FolderModel, userKeymap: URL = CommandCenter.userKeymapURL) {
        self.table = table
        self.folder = folder
        let resolved = Keymap.resolve(table: table, userFile: try? Data(contentsOf: userKeymap))
        keymap = resolved.keymap
        keymapProblems = resolved.problems
        for problem in resolved.problems { Self.log.error("\(problem, privacy: .public)") }
        var router = KeyRouter(keymap: resolved.keymap)
        if let t = UserDefaults.standard.object(forKey: "keyHoldThresholdSeconds") as? Double, t > 0 { router.holdThreshold = t }
        self.router = router
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
            default: break
            }
        }
        guard let c = KeyLabels.label(for: spec).lowercased().first else { return nil }
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
        guard let window = event.window, window.isKeyWindow, !(window is NSPanel),
              let input = KeyInput(event: event, layout: KeyLayout.asciiCapable())
        else { return false }
        let focus: KeyFocus = if let tv = window.firstResponder as? NSTextView, tv.isEditable || tv.isFieldEditor {
            .textInput
        } else { .canvas }
        if event.type == .keyDown, focus == .canvas,
           event.modifierFlags.isDisjoint(with: [.command, .control]),
           inspectorKey(event.keyCode, event.modifierFlags.contains(.shift), event.modifierFlags.contains(.option)) { return true }
        let result = router.handle(input, mode: mode, focus: focus)
        apply(result.actions)
        return result.consumed
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
