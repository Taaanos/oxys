# F-05 · Keyboard routing

Code: `Packages/Commands` (`PhysicalKey`, `Keymap`, `KeyRouter`, `KeyLayout`, `KeyLabels`), 19 unit tests. Throwaway window: `App/Oxys/KeySpike.swift`, shown when you launch with `OXYS_KEY_SPIKE=1`.

```sh
make build && OXYS_KEY_SPIKE=1 build/Build/Products/Release/Oxys.app/Contents/MacOS/Oxys
```

## Design

1. **One local monitor** (`NSEvent.addLocalMonitorForEvents` for key-down and key-up) turns each event into a `KeyInput` and asks a `KeyRouter` (a plain value type, no AppKit) what to do. It returns `nil` for events the router consumed, so neither the menu bar nor the responder chain sees them. That is what stops a menu item that shows the same key from firing twice. Menu items carry the shortcut for display and for mouse use only.
2. **Matching** (`Keymap`): a binding is either `.position(PhysicalKey)` or `.character(Character)`.
   - Position: letters, digits, arrows, `Space`, `Esc`, matched on `keyCode` and all four modifiers exactly. Input source never enters into it, so Greek, Russian and Japanese layouts behave like US.
   - Character: `[ ] \ = - ?`. The adapter asks the **ASCII-capable layout** (`TISCopyCurrentASCIICapableKeyboardLayoutInputSource`, then `UCKeyTranslate`) what the event's key types with its `⇧`/`⌥`, and the binding matches on that character. `⌘` and `⌃` still have to match. A layout that moves `?` to another key still works; a key that types something else at the US position does not fire it.
   - `⌘` chords (`⌘A`, `⌘R`, `⌘Z`) are positional bindings in the same table, so they work on non-Latin layouts without relying on the system's Latin fallback for menu key equivalents. Chords not in the table (`⌘Q`, `⌘W`, `⌘,`) pass through to the menu bar untouched.
3. **Behaviors** per binding: `once` (auto-repeat swallowed, G-12), `repeating` (navigation, zoom steps), `toggleOrHold`.
4. **Tap vs hold** uses event timestamps, no timers. Key-down performs the toggle at once (so a hold shows the result immediately). On key-up, if the key was down for at least the threshold (250 ms, `keyHoldThresholdSeconds` default), the router emits `releaseHold`, which the command treats as "toggle again"; a shorter press is a tap and leaves the toggle. Auto-repeat of a held toggle key is swallowed. If the window resigns key with keys down, `cancelAll` reverts toggles that were already past the threshold.
   *Compared with "first auto-repeat event":* that depends on the user's system key-repeat delay (up to about 2 s), so a fixed threshold is the more predictable of the two. Not built, not needed.
5. **Text input**: when the first responder is a text view (field editors included), the router passes everything through except `Esc`, which emits `returnFocusToCanvas` and is consumed together with its key-up. The next `Esc` is then an ordinary canvas key (G-13).
6. **Labels**: `KeyLabels.label(for:)` prints position bindings from the current layout if it types Latin, else from the ASCII-capable layout; character bindings print the character. On Dvorak the `X`-position binding is labeled `Q`, which is the key the user has to find.

## Checked

| Criterion | How | Result |
| --- | --- | --- |
| `X`, `1`–`5`, `[ ] \ = - ?` on Greek / Russian | Unit tests route the real events' key codes; Greek and Russian layout data (`com.apple.keylayout.*`) confirm `X` types χ / ч while the key code is unchanged; a synthesized `NSEvent` with `characters: "χ"` routes to the reject command | pass |
| `⌘A`, `⌘R`, `⌘Z` on those layouts | Unit test with non-Latin characters in the events | pass |
| Hold `Z` 0.5 s reverts, tap toggles | Router tests with timestamps (also a configurable threshold, focus loss, modifier released before the key) | pass |
| Typing in a search field triggers nothing | Router test, plus `Esc` hands focus back | pass at router level |
| Live check in the spike window with a Greek / Russian / Japanese source, menu double-fire, text field `Esc` | **Not run**: the session cannot send key events (no Accessibility permission). Checklist below | open |

### Manual checklist (spike window)

1. Launch with `OXYS_KEY_SPIKE=1`. With the ABC layout: press `X`, `3`, `⇧3`, `[`, `?`, `⌘Z`. Each line in the log says `key:`, and the "menu" count next to each command stays absent. A `MENU:` line right after a key press means a double fire.
2. Switch to Greek, then Russian, then Japanese (Hiragana): repeat. The header shows the input source.
3. Tap `Z` (toggles fit/1:1), hold `Z` for half a second (1:1 while down, back on release). Hold `3`: one `cull.rate3` only. Hold `→`: repeats.
4. Click the text field, type `x3z`: no log lines, text appears. `Esc`: "focus → canvas". `Esc` again: `nav.grid`.
5. Choose Spike → Reject with the mouse: one `MENU:` line.

## Limits and notes for later stories

- Punctuation on layouts where `[` needs `⌥` (German) works because `⌥` is part of producing the character, but it then cannot be told apart from a `⌥`+punctuation binding; no such binding exists. Position bindings for punctuation stay available through `.position`.
- Dead keys and IME composition are not handled specially: the monitor sees raw events before the input method, and bare keys only route when a text view is not first responder. A marked-text session in a text field is protected by the same rule.
- Numeric keypad digits are not aliased to the digit row (they have other key codes); M-05 should decide.
- `TISCopy…` must run on the main thread, so layout lookups are `@MainActor`. The adapter looks the layout up per event (cheap next to a frame); cache it with the input-source-changed notification if a profile ever shows it.
- Signposts: the router is allocation-free and runs in microseconds; the `key-to-frame` interval begins in the canvas (M-03), where the frame it ends on exists. The monitor should call `Perf.begin(.keyToFrame)` there.
- `NSEvent` timestamps are system uptime seconds; the spike's focus-loss path uses `systemUptime` to match.
