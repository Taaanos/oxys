import Foundation
import Testing
@testable import Commands

// MARK: - Deterministic PRNG (SplitMix64)

private struct SeededRNG {
    private var state: UInt64

    init(seed: UInt64) { self.state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    mutating func int(in range: ClosedRange<Int>) -> Int {
        let span = UInt64(range.upperBound - range.lowerBound) + 1
        return range.lowerBound + Int(next() % span)
    }

    mutating func double(in range: ClosedRange<Double>) -> Double {
        let u = Double(next() & 0x001F_FFFF_FFFF_FFFF) / Double(0x0020_0000_0000_0000)
        return range.lowerBound + u * (range.upperBound - range.lowerBound)
    }

    mutating func bool(probability num: Int = 1, outOf den: Int = 2) -> Bool {
        Int(next() % UInt64(den)) < num
    }

    mutating func pick<T>(_ items: [T]) -> T {
        items[Int(next() % UInt64(items.count))]
    }
}

private func hex(_ seed: UInt64) -> String { "0x" + String(seed, radix: 16, uppercase: true) }

// MARK: - Suite 1: KeyRouter Stateful Simulation

@Suite struct KeyRouterSimulationTests {
    private struct ExpectedHold {
        let command: CommandID
        let since: Double
    }

    @Test(arguments: [UInt64(0xC101), 0xC102, 0xC103, 0xC104, 0xC105, 0xC106])
    func keyRouterRespectsHoldThresholdFocusAndCancelInvariants(seed: UInt64) {
        var rng = SeededRNG(seed: seed)
        let resolved = Keymap.resolve(table: .standard, file: nil, presets: KeymapPreset.bundled)
        let threshold = 0.25
        var router = KeyRouter(keymap: resolved.keymap, holdThreshold: threshold)

        let allKeys = PhysicalKey.allCases
        let modifierCombos: [KeyModifiers] = [[], .shift, .option, .command, [.shift, .command], [.option, .command]]
        let modes = ViewMode.allCases

        var now = 10.0
        var downKeys: Set<UInt16> = []
        var expectedHolds: [UInt16: ExpectedHold] = [:]
        var consumedDowns: Set<UInt16> = []

        for step in 0..<400 {
            now += rng.double(in: 0.01...0.40)
            let mode = rng.pick(modes)

            // Occasional window resign / cancelAll
            if rng.bool(probability: 1, outOf: 25) {
                let actions = router.cancelAll(at: now)
                let expectedReleased = Set(expectedHolds.values.filter { now - $0.since >= threshold }.map(\.command))
                let gotReleased = Set(actions.compactMap { action -> CommandID? in
                    if case .releaseHold(let id) = action { return id }
                    return nil
                })
                #expect(gotReleased == expectedReleased,
                        "seed=\(hex(seed)) step=\(step): cancelAll released \(gotReleased) expected \(expectedReleased)")
                #expect(actions.count == expectedReleased.count,
                        "seed=\(hex(seed)) step=\(step): unexpected non-releaseHold actions from cancelAll")
                expectedHolds.removeAll()
                consumedDowns.removeAll()
                downKeys.removeAll()
                continue
            }

            let focus: KeyFocus = rng.bool(probability: 1, outOf: 6) ? .textInput : .canvas

            // Decide whether to release a down key, repeat a down key, or press a new key.
            let choice = rng.int(in: 0...4)
            if !downKeys.isEmpty && choice == 0 {
                // Key up on a currently pressed key (possibly with different modifiers or mode!)
                let code = rng.pick(downKeys.sorted())
                downKeys.remove(code)
                let mods = rng.pick(modifierCombos)
                let result = router.handle(KeyInput(keyCode: code, modifiers: mods, isDown: false, timestamp: now),
                                           mode: mode, focus: focus)
                if consumedDowns.remove(code) != nil {
                    #expect(result.consumed, "seed=\(hex(seed)) step=\(step): matching key-up was not consumed")
                    if let hold = expectedHolds.removeValue(forKey: code) {
                        if now - hold.since >= threshold {
                            #expect(result.actions == [.releaseHold(hold.command)],
                                    "seed=\(hex(seed)) step=\(step): hold past threshold did not emit releaseHold")
                        } else {
                            #expect(result.actions.isEmpty,
                                    "seed=\(hex(seed)) step=\(step): tap under threshold emitted \(result.actions)")
                        }
                    } else {
                        #expect(result.actions.isEmpty,
                                "seed=\(hex(seed)) step=\(step): non-hold key-up emitted actions \(result.actions)")
                    }
                } else {
                    #expect(result == .passThrough,
                            "seed=\(hex(seed)) step=\(step): unowned key-up was consumed")
                }
            } else if !downKeys.isEmpty && choice == 1 {
                // Key repeat on a currently pressed key that we already own
                guard !consumedDowns.isEmpty else { continue }
                let code = rng.pick(consumedDowns.sorted())
                let mods = rng.pick(modifierCombos)
                let result = router.handle(KeyInput(keyCode: code, modifiers: mods, isDown: true, isRepeat: true, timestamp: now),
                                           mode: mode, focus: focus)
                if focus == .textInput {
                    let isPlainEsc = code == PhysicalKey.escape.rawValue && mods.isDisjoint(with: [.command, .control, .option])
                    if isPlainEsc {
                        #expect(result == .consumed(), "seed=\(hex(seed)) step=\(step): repeated Esc in textInput should consume silently")
                    } else {
                        #expect(result == .passThrough, "seed=\(hex(seed)) step=\(step): textInput repeat should pass through")
                    }
                } else if expectedHolds[code] != nil {
                    // toggleOrHold repeats must be swallowed silently so they don't re-toggle!
                    #expect(result == .consumed(), "seed=\(hex(seed)) step=\(step): toggleOrHold repeat fired an action")
                }
            } else {
                // Fresh key-down on a key not currently held
                let key = rng.pick(allKeys)
                let code = key.rawValue
                guard !downKeys.contains(code) else { continue }
                let mods = rng.pick(modifierCombos)
                let char: Character? = key.usLabel.count == 1 ? key.usLabel.lowercased().first : nil
                let input = KeyInput(keyCode: code, modifiers: mods, isDown: true, isRepeat: false, timestamp: now, character: char)
                let result = router.handle(input, mode: mode, focus: focus)
                downKeys.insert(code)

                if focus == .textInput {
                    let isPlainEsc = code == PhysicalKey.escape.rawValue && mods.isDisjoint(with: [.command, .control, .option])
                    if isPlainEsc {
                        #expect(result == .consumed(.returnFocusToCanvas),
                                "seed=\(hex(seed)) step=\(step): Esc in textInput must return focus to canvas")
                        consumedDowns.insert(code)
                    } else {
                        #expect(result == .passThrough,
                                "seed=\(hex(seed)) step=\(step): non-Esc key in textInput was consumed")
                    }
                } else if result.consumed {
                    consumedDowns.insert(code)
                    if let binding = resolved.keymap.match(keyCode: code, modifiers: mods, character: char, mode: mode),
                       binding.behavior == .toggleOrHold {
                        expectedHolds[code] = ExpectedHold(command: binding.command, since: now)
                    }
                }
            }
        }
    }

    /// Regression test for a bug found by `KeyRouterSimulationTests` (seeds 0xC101..0xC106): an `isRepeat: true`
    /// event for a key whose initial key-down was NOT owned (e.g. pressed in a text field) used to fall through and
    /// fire as a brand-new key-down, triggering `.once` / `.toggleOrHold` on auto-repeat and stranding a hold.
    @Test func unownedKeyRepeatDoesNotFireFreshBinding() {
        let resolved = Keymap.resolve(table: .standard, file: nil, presets: KeymapPreset.bundled)
        var router = KeyRouter(keymap: resolved.keymap, holdThreshold: 0.25)
        // 1. Key 'f' (focus peaking, toggleOrHold) pressed while typing in a text field -> passed through.
        let down = router.handle(KeyInput(keyCode: PhysicalKey.f.rawValue, isDown: true, isRepeat: false, timestamp: 1.0, character: "f"),
                                 mode: .loupe, focus: .textInput)
        #expect(down == .passThrough)
        // 2. Focus returns to canvas while key is still held, and an auto-repeat arrives.
        let rep = router.handle(KeyInput(keyCode: PhysicalKey.f.rawValue, isDown: true, isRepeat: true, timestamp: 1.3, character: "f"),
                                mode: .loupe, focus: .canvas)
        #expect(rep == .passThrough)
        // And nothing is stranded: the eventual key-up is not ours either.
        let up = router.handle(KeyInput(keyCode: PhysicalKey.f.rawValue, isDown: false, timestamp: 2.0), mode: .loupe, focus: .canvas)
        #expect(up == .passThrough)
    }
}

// MARK: - Suite 2: KeymapEditor Differential & Conflict-Freedom Tests

@Suite struct KeymapEditorSimulationTests {
    @Test(arguments: [UInt64(0xE101), 0xE102, 0xE103, 0xE104, 0xE105, 0xE106])
    func editorMaintainsConflictFreedomAndJSONRoundTrip(seed: UInt64) throws {
        var rng = SeededRNG(seed: seed)
        let table = CommandTable.standard
        let presets = KeymapPreset.bundled
        var editor = KeymapEditor(table: table, presets: presets)
        let commands = table.commands.map(\.id)
        let candidateKeys = PhysicalKey.allCases
        let candidateMods: [KeyModifiers] = [[], .option, .command, [.shift, .command], [.option, .command]]

        for step in 0..<120 {
            switch rng.int(in: 0...9) {
            case 0...4:
                // Try assigning a random shortcut to a random command (with or without reassign).
                let id = rng.pick(commands)
                let key = rng.pick(candidateKeys)
                let mods = rng.pick(candidateMods)
                let shortcut = Shortcut(.position(key), mods)
                let existing = editor.shortcuts(for: id)
                let replacing = (!existing.isEmpty && rng.bool()) ? rng.pick(existing) : nil
                let reassign = rng.bool()

                let preCheck = editor.check(shortcut, for: id, replacing: replacing)
                let outcome = editor.assign(shortcut, to: id, replacing: replacing, reassign: reassign)

                switch preCheck {
                case .ok:
                    #expect(outcome == .ok, "seed=\(hex(seed)) step=\(step): check was .ok but assign returned \(outcome)")
                    #expect(editor.shortcuts(for: id).contains(shortcut),
                            "seed=\(hex(seed)) step=\(step): assigned shortcut missing")
                case .duplicate, .reserved:
                    #expect(outcome == preCheck, "seed=\(hex(seed)) step=\(step): duplicate/reserved should not assign")
                case .conflicts(let list):
                    if reassign && list.allSatisfy({ $0.isReassignable }) {
                        #expect(outcome == .ok, "seed=\(hex(seed)) step=\(step): reassignable conflict failed")
                        #expect(editor.shortcuts(for: id).contains(shortcut))
                    } else {
                        #expect(outcome == preCheck, "seed=\(hex(seed)) step=\(step): non-reassignable conflict should be rejected")
                    }
                }

            case 5...6:
                // Remove one shortcut from a random command.
                let id = rng.pick(commands)
                let keys = editor.shortcuts(for: id)
                if !keys.isEmpty {
                    let k = rng.pick(keys)
                    editor.remove(k, from: id)
                    #expect(!editor.shortcuts(for: id).contains(k),
                            "seed=\(hex(seed)) step=\(step): removed shortcut still present")
                }

            case 7:
                // Reset one command back to its preset/default.
                let id = rng.pick(commands)
                editor.reset(id)
                #expect(!editor.isCustomized(id), "seed=\(hex(seed)) step=\(step): reset command still marked customized")

            case 8:
                // Switch preset (or back to Default).
                let presetID: String? = rng.bool() ? nil : presets.first?.id
                let selected = editor.selectPreset(presetID)
                #expect(selected)
                #expect(editor.customizedCount == 0)

            default:
                // Reset all customizations.
                editor.resetAll()
                #expect(editor.customizedCount == 0)
            }

            // Global invariants after every single edit:
            // 1. Resolved keymap has zero problems.
            #expect(editor.resolved.problems.isEmpty,
                    "seed=\(hex(seed)) step=\(step): resolved problems \(editor.resolved.problems)")

            // 2. Periodically verify JSON encode/decode resolves to the exact same keymap.
            if step % 10 == 0 {
                let data = try editor.file.encoded()
                let reloaded = Keymap.resolve(table: table, userFile: data, presets: presets)
                #expect(reloaded.problems.isEmpty, "seed=\(hex(seed)) step=\(step): JSON reload had problems")
                for id in commands {
                    #expect(reloaded.keymap.shortcuts(for: id) == editor.shortcuts(for: id),
                            "seed=\(hex(seed)) step=\(step): JSON round-trip differed for \(id.rawValue)")
                }
            }
        }
    }
}

// MARK: - Suite 3: FocusMode Property Tests

@Suite struct FocusModePropertyTests {
    @Test(arguments: [UInt64(0xF101), 0xF102, 0xF103, 0xF104])
    func focusModeNeverMutatesSavedStateAndRestoresCleanly(seed: UInt64) {
        var rng = SeededRNG(seed: seed)
        var focus = FocusMode()
        var saved = Dictionary(uniqueKeysWithValues: Panel.allCases.map { ($0, rng.bool()) })

        for step in 0..<250 {
            switch rng.int(in: 0...3) {
            case 0:
                let savedBefore = saved
                focus.toggle()
                // Toggling focus mode NEVER changes saved panel states.
                #expect(saved == savedBefore)
                if focus.isOn {
                    #expect(focus.revealed.isEmpty, "seed=\(hex(seed)) step=\(step): entering focus mode left revealed non-empty")
                    for p in Panel.allCases {
                        #expect(!focus.isVisible(p, saved: saved[p]!),
                                "seed=\(hex(seed)) step=\(step): panel \(p) visible right after entering focus mode")
                    }
                } else {
                    #expect(focus.revealed.isEmpty)
                    for p in Panel.allCases {
                        #expect(focus.isVisible(p, saved: saved[p]!) == saved[p]!,
                                "seed=\(hex(seed)) step=\(step): panel \(p) visibility != saved after exiting focus mode")
                    }
                }

            case 1:
                let p = rng.pick(Panel.allCases)
                // Commands like ⌘F turn the panel on (`saved = true`) alongside calling `reveal`.
                saved[p] = true
                focus.reveal(p)
                if focus.isOn {
                    #expect(focus.revealed.contains(p))
                    #expect(focus.isVisible(p, saved: true))
                    #expect(!focus.isVisible(p, saved: false))
                } else {
                    #expect(focus.revealed.isEmpty)
                }

            default:
                let p = rng.pick(Panel.allCases)
                let wasVisible = focus.isVisible(p, saved: saved[p]!)
                let outcome = focus.press(p, saved: saved[p]!)
                switch outcome {
                case .toggle:
                    saved[p]!.toggle()
                case .reveal:
                    #expect(focus.isOn && saved[p]!)
                case .turnOnAndReveal:
                    #expect(focus.isOn && !saved[p]!)
                    saved[p] = true
                }
                let nowVisible = focus.isVisible(p, saved: saved[p]!)
                // Pressing a panel's key always flips its on-screen visibility!
                #expect(nowVisible == !wasVisible,
                        "seed=\(hex(seed)) step=\(step): press(\(p)) did not flip visibility (was=\(wasVisible), now=\(nowVisible))")
            }
        }
    }

    /// Minimal reproducer discovered by `FocusModePropertyTests` (seed=0xF104 step=205):
    /// If a panel is in `revealed` while `saved` is `false` (e.g., revealed in focus mode and then dismissed via a
    /// close button without going through `press`, or `reveal` called on an off panel), calling `press(panel, saved: false)`
    /// removes it from `revealed` and returns `.toggle`—flipping `saved` to `true` while leaving the panel invisible!
    @Test func pressingRevealedButSavedOffPanelShowsIt() {
        var focus = FocusMode()
        focus.toggle()             // enter focus mode
        focus.reveal(.inspector)   // panel is in `revealed`
        var saved = false          // panel was closed / saved off
        #expect(!focus.isVisible(.inspector, saved: saved))
        let outcome = focus.press(.inspector, saved: saved)
        switch outcome {
        case .toggle: saved.toggle()
        case .reveal: break
        case .turnOnAndReveal: saved = true
        }
        #expect(focus.isVisible(.inspector, saved: saved))
    }
}
