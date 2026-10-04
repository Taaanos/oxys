#if OXYS_DEV_HOOKS
import AppKit
import Commands
import Foundation
import Library

/// V-14: checks the keymap path inside the running app, with key events built in code and sent through
/// `NSApp.sendEvent`, the way the system delivers them. It needs no Accessibility permission, so a script can run it.
/// Set `OXYS_KEYS_SELFTEST=1`, `OXYS_OPEN=<folder with photos>`, `OXYS_KEYMAP=<a file that does not exist yet>` and
/// `OXYS_SELFTEST_OUT=<file>`; the app runs the steps, writes one line per check and quits. Does nothing otherwise.
/// `scripts/keys-selftest.sh` does the setup.
@MainActor
enum KeysSelfTest {
    static var enabled: Bool { DevHooks.environment["OXYS_KEYS_SELFTEST"] != nil }

    private static var lines: [String] = []
    private static var failures = 0

    static func start(model: AppModel, folder url: URL) {
        Task { @MainActor in
            await run(model: model, url: url)
            let out = DevHooks.environment["OXYS_SELFTEST_OUT"]
            lines.append("done failures=\(failures)")
            if let out { try? (lines.joined(separator: "\n") + "\n").write(toFile: out, atomically: true, encoding: .utf8) }
            try? await Task.sleep(for: .milliseconds(300))
            NSApp.terminate(nil)
        }
    }

    // MARK: helpers

    private static func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
        if !ok { failures += 1 }
        lines.append(ok ? "PASS \(name)" : "FAIL \(name) \(detail())")
        // Written as it goes, so a run that hangs still shows how far it got.
        if let out = DevHooks.environment["OXYS_SELFTEST_OUT"] { try? (lines.joined(separator: "\n") + "\n").write(toFile: out, atomically: true, encoding: .utf8) }
    }

    private static func wait(_ seconds: Double = 0.15) async { try? await Task.sleep(for: .milliseconds(Int(seconds * 1000))) }

    private static func until(_ seconds: Double = 10, _ done: () -> Bool) async -> Bool {
        let start = ContinuousClock.now
        while !done() {
            if start.duration(to: .now) > .seconds(seconds) { return false }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return true
    }

    /// A key press, down then up, to `window`.
    private static func press(_ key: PhysicalKey, _ flags: NSEvent.ModifierFlags = [], in window: NSWindow) async {
        let typed = key.hasFixedLabel ? "" : key.usLabel.lowercased()
        for down in [true, false] {
            guard let event = NSEvent.keyEvent(
                with: down ? .keyDown : .keyUp, location: .zero, modifierFlags: flags,
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                characters: typed, charactersIgnoringModifiers: typed, isARepeat: false, keyCode: key.rawValue)
            else { continue }
            NSApp.sendEvent(event)
        }
        await wait()
    }

    /// The key equivalent the menu bar shows for an item, or nil when no item has the title. SwiftUI fills a menu in
    /// when it opens (`menuNeedsUpdate`), so each menu is asked to update first, as AppKit does before it shows one.
    private static func menuKey(_ title: String, in menu: NSMenu? = NSApp.mainMenu) -> String? {
        guard let menu else { return nil }
        for item in menu.items {
            if let submenu = item.submenu { submenu.delegate?.menuNeedsUpdate?(submenu) }
            if item.title == title { return item.keyEquivalent }
            if let found = menuKey(title, in: item.submenu) { return found }
        }
        return nil
    }

    // MARK: the steps

    private static func run(model: AppModel, url: URL) async {
        let folder = model.folder, commands = model.commands, store = model.keymapStore
        let reject: CommandID = "cull.reject"

        model.open(url)
        commands.mode = .loupe
        guard await until(30, { folder.currentPhoto != nil && NSApp.windows.contains { $0.isVisible && !($0 is NSPanel) } }),
              let main = NSApp.windows.first(where: { $0.isVisible && !($0 is NSPanel) }) else {
            check("the folder opens", false, "no photo or no window")
            return
        }
        // Other apps may have the focus while this runs, and macOS will not always give it to Oxys, so the monitor is
        // told to take the window an event names as the key window (the check of key status is not what is tested here).
        commands.selfTestTakesAnyWindowAsKey = true
        await wait(1)
        lines.append("INFO first responder in the photo window: \(main.firstResponder.map { String(describing: type(of: $0)) } ?? "none")")
        // The photo has the keyboard, as it does when a user is culling (a text field or control would keep the keys).
        main.makeFirstResponder(nil)
        func decision() -> Decision? { folder.currentPhoto?.decision }
        func clear() async {
            commands.perform("cull.rate.0")
            await wait()
        }
        await clear()

        // 1. The Default keys work through the monitor.
        await press(.x, in: main)
        check("X rejects with the Default keys", decision()?.isReject == true)
        await clear()

        // 2. A remap made in the store reaches the keymap, the file and the menu at once.
        let remap = store.assign(Shortcut(.position(.q)), to: reject, replacing: Shortcut(.position(.x)))
        check("recording Q for Reject is accepted", remap == .ok, "\(String(describing: remap))")
        check("the file was written", FileManager.default.fileExists(atPath: store.url.path))
        check("the command center has the new key", commands.keymap.shortcuts(for: reject) == [Shortcut(.position(.q))])
        check("the Photo menu shows Q for Reject", menuKey("Reject") == "q", "menu key: \(menuKey("Reject") ?? "none")")
        await press(.x, in: main)
        check("X no longer rejects", decision()?.isReject == false)
        await press(.q, in: main)
        check("Q rejects", decision()?.isReject == true)
        await clear()

        // 3. While the Keys pane records, every key goes to the recorder and nothing runs.
        var captured: [KeyInput] = []
        commands.keyCapture = { captured.append($0) }
        await press(.q, in: main)
        await press(.z, [.command], in: main)
        await press(.escape, in: main)
        commands.keyCapture = nil
        check("the recorder gets Q, ⌘Z and Esc", captured.map(\.keyCode) == [PhysicalKey.q, .z, .escape].map(\.rawValue),
              "\(captured.map(\.keyCode))")
        check("Q did not reject while recording", decision()?.isReject == false)
        check("the recorder saw ⌘ and read Esc as cancel",
              captured.dropFirst().first?.modifiers == [.command] && Shortcut.capture(captured.last!) == .cancel)

        // 4. The Settings window does not run cull keys.
        let settingsItem = NSApp.mainMenu?.items.first?.submenu?.items.first { $0.title == "Settings…" }
        let sent = settingsItem.flatMap { item in item.action.map { NSApp.sendAction($0, to: item.target, from: item) } } ?? false
        let opened = await until(5) { commands.settingsWindow?.isVisible == true }
        if !sent { lines.append("INFO the Settings menu item was not found or did not act") }
        check("the Settings window opens and is known to the command center", opened)
        if let settings = commands.settingsWindow {
            settings.makeKeyAndOrderFront(nil)
            check("Settings is on screen", settings.isVisible)
            lines.append("INFO first responder in Settings: \(settings.firstResponder.map { String(describing: type(of: $0)) } ?? "none")")
            // Nothing focused: the case where the monitor would route the key as it does in the photo window.
            settings.makeFirstResponder(nil)
            await press(.q, in: settings)
            await press(.digit3, in: settings)
            check("Q and 3 in Settings change nothing", decision()?.isUndecided == true, "\(String(describing: decision()))")
            await keysPaneSteps(model: model, settings: settings)
            settings.close()
        }
        store.resetAll()
        await wait()

        // 5. A conflict is reported first, and reassigning moves the key.
        let before = try? Data(contentsOf: store.url)
        let clash = store.assign(Shortcut(.position(.e)), to: reject)
        if case .conflicts(let list)? = clash {
            check("E is reported as the key of Open in Loupe", list.map(\.command) == ["view.loupe"])
        } else {
            check("E is reported as the key of Open in Loupe", false, "\(String(describing: clash))")
        }
        check("a conflict leaves the file as it was", (try? Data(contentsOf: store.url)) == before)
        check("reassigning E is accepted", store.assign(Shortcut(.position(.e)), to: reject, reassign: true) == .ok)
        check("Open in Loupe lost E", commands.keymap.shortcuts(for: "view.loupe") == [Shortcut(.position(.return)), Shortcut(.position(.space))])
        await press(.e, in: main)
        check("E rejects", decision()?.isReject == true)
        await clear()

        // 6. Reset puts every key back.
        store.resetAll()
        check("Reset All removes the file", !FileManager.default.fileExists(atPath: store.url.path))
        check("the Default keys are back", commands.keymap.shortcuts(for: reject) == [Shortcut(.position(.x))]
              && commands.keymap.shortcuts(for: "view.loupe").first == Shortcut(.position(.e)))
        check("the Photo menu shows X again", menuKey("Reject") == "x", "menu key: \(menuKey("Reject") ?? "none")")
        await press(.x, in: main)
        check("X rejects again", decision()?.isReject == true)
        await clear()

        // 7. The Photo Mechanic key set: it is in the app bundle, `⌃3` rates, the Default `3` still does, and nil goes back.
        check("the Photo Mechanic key set is in the app", store.editor.presets.contains { $0.id == "photomechanic" })
        store.selectPreset("photomechanic")
        check("the file names the key set", (try? String(contentsOf: store.url, encoding: .utf8))?.contains("\"preset\" : \"photomechanic\"") == true)
        check("Rate 3 Stars has ⌃3 first", commands.keymap.shortcuts(for: "cull.rate.3").first == Shortcut(.position(.digit3), [.control]))
        await press(.digit3, [.control], in: main)
        check("⌃3 rates 3 stars", decision()?.rating == 3, "\(String(describing: decision()))")
        await clear()
        await press(.digit3, in: main)
        check("3 still rates 3 stars", decision()?.rating == 3, "\(String(describing: decision()))")
        await clear()
        store.selectPreset(nil)
        check("the Default keys are back and the file is gone",
              commands.keymap.shortcuts(for: "cull.rate.3").first == Shortcut(.position(.digit3)) && !FileManager.default.fileExists(atPath: store.url.path))
        await press(.digit3, [.control], in: main)
        check("⌃3 does nothing on the Default keys", decision()?.isUndecided == true, "\(String(describing: decision()))")

        // 8. A file edited outside the app is read when the app becomes active; a file Oxys cannot read blocks editing.
        try? Data(#"{"version":1,"bindings":{"nav.last":[{"position":"l"}]}}"#.utf8).write(to: store.url)
        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: NSApp)
        await wait()
        check("a hand edit is picked up", commands.keymap.shortcuts(for: "nav.last") == [Shortcut(.position(.l))])
        let garbage = Data("not json".utf8)
        try? garbage.write(to: store.url)
        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: NSApp)
        await wait()
        check("an unreadable file blocks editing", store.isBlocked)
        check("the Default keys are on while it is blocked", commands.keymap.shortcuts(for: "nav.last") == [Shortcut(.position(.end))])
        check("a blocked store refuses an edit", store.assign(Shortcut(.position(.q)), to: reject) == nil)
        check("the unreadable file was not touched", (try? Data(contentsOf: store.url)) == garbage)
        store.startOver()
        check("Start Over keeps the old file as .bak", FileManager.default.fileExists(atPath: store.url.appendingPathExtension("bak").path)
              && !FileManager.default.fileExists(atPath: store.url.path))
        check("and the store works again", !store.isBlocked)
        try? FileManager.default.removeItem(at: store.url.appendingPathExtension("bak"))
    }

    /// What a user does in Settings → Keys, through the pane's own model: the monitor hands the keys to the recorder.
    private static func keysPaneSteps(model: AppModel, settings: NSWindow) async {
        let keys = model.keysModel, commands = model.commands
        let reject: CommandID = "cull.reject"
        func reached(_ phrase: String) -> Bool { keys.notice?.text.contains(phrase) == true }

        // Change a key in place.
        keys.startRecording(.init(command: reject, replacing: Shortcut(.position(.q))))
        await press(.w, in: settings)
        check("recording W in place of Q", keys.recording == nil && commands.keymap.shortcuts(for: reject) == [Shortcut(.position(.w))],
              "\(commands.keymap.shortcuts(for: reject))")

        // A key macOS owns is refused, and the recorder stays on for another try.
        keys.startRecording(.init(command: reject, replacing: nil))
        await press(.q, [.command], in: settings)
        check("⌘Q is refused with its owner named, and the app keeps running", reached("Quit Oxys") && keys.recording != nil,
              "\(String(describing: keys.notice?.text))")
        await press(.escape, in: settings)
        check("Esc stops recording and keeps the keys", keys.recording == nil && keys.notice == nil
              && commands.keymap.shortcuts(for: reject) == [Shortcut(.position(.w))])

        // The twin of another command's key is named, not offered.
        keys.startRecording(.init(command: "info.cycle", replacing: nil))
        await press(.w, [.shift], in: settings)
        check("⇧W is named as the twin of Reject's W", reached("apply-and-move") && keys.notice?.pending == nil && keys.recording != nil,
              "\(String(describing: keys.notice?.text))")
        await press(.escape, in: settings)

        // A key another command has is reported first; Reassign moves it.
        keys.startRecording(.init(command: "info.cycle", replacing: nil))
        await press(.e, in: settings)
        check("E is offered for reassignment from Open in Loupe", reached("Open in Loupe") && keys.notice?.pending != nil && keys.recording == nil,
              "\(String(describing: keys.notice?.text))")
        check("nothing changed yet", commands.keymap.shortcuts(for: "info.cycle") == [Shortcut(.position(.i))])
        // OXYS_SELFTEST_SHOT=<file.png> draws the Settings window into a file (this window only, no screen capture).
        if let path = DevHooks.environment["OXYS_SELFTEST_SHOT"], let view = settings.contentView?.superview ?? settings.contentView {
            keys.search = "cycle info"
            await wait(1)
            if let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
            }
        }
        keys.reassign()
        check("Reassign gives E to Cycle Info and takes it from Open in Loupe",
              commands.keymap.shortcuts(for: "info.cycle") == [Shortcut(.position(.i)), Shortcut(.position(.e))]
              && commands.keymap.shortcuts(for: "view.loupe") == [Shortcut(.position(.return)), Shortcut(.position(.space))])
    }
}
#endif
