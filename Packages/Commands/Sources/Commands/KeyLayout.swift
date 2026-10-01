import AppKit
import Carbon.HIToolbox

/// Text Input Sources must be queried on the main thread, so every way to obtain a layout is `@MainActor`;
/// translating with one already obtained is thread-safe.
/// Asks a keyboard layout what a physical key types. Backed by `UCKeyTranslate` on the layout's `uchr` data.
public struct KeyLayout: Sendable {
    private let layoutData: Data
    public let sourceID: String

    @MainActor private init?(source: TISInputSource) {
        guard let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let cfData = Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue()
        layoutData = cfData as Data
        if let id = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) {
            sourceID = Unmanaged<CFString>.fromOpaque(id).takeUnretainedValue() as String
        } else {
            sourceID = ""
        }
    }

    /// The layout the user is typing on, which may be non-Latin (Greek, Russian) or a Japanese kana layout.
    /// Input methods without layout data (Japanese Hiragana) fall back to the ASCII-capable layout.
    @MainActor public static func current() -> KeyLayout? {
        if let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
           let layout = KeyLayout(source: source) { return layout }
        return asciiCapable()
    }

    /// The Latin layout that stands in for a non-Latin one: the current layout if it can type ASCII,
    /// else the most recently used ASCII-capable layout (what `⌘` shortcuts use on non-Latin layouts).
    @MainActor public static func asciiCapable() -> KeyLayout? {
        guard let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue() else { return nil }
        return KeyLayout(source: source)
    }

    /// A specific installed layout, such as `com.apple.keylayout.Greek`. For tests and diagnostics.
    @MainActor public static func installed(id: String) -> KeyLayout? {
        let filter = [kTISPropertyInputSourceID as String: id] as CFDictionary
        guard let list = TISCreateInputSourceList(filter, true)?.takeRetainedValue() as? [TISInputSource],
              let first = list.first else { return nil }
        return KeyLayout(source: first)
    }

    /// What `keyCode` types with `⇧` and/or `⌥` held; nil for dead keys and keys that type nothing.
    public func character(keyCode: UInt16, shift: Bool = false, option: Bool = false) -> Character? {
        var carbonModifiers: UInt32 = 0
        if shift { carbonModifiers |= UInt32(shiftKey >> 8) }
        if option { carbonModifiers |= UInt32(optionKey >> 8) }
        var deadKeyState: UInt32 = 0
        var chars = [UniChar](repeating: 0, count: 4)
        var length = 0
        let status = layoutData.withUnsafeBytes { buffer -> OSStatus in
            guard let layout = buffer.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return -1 }
            return UCKeyTranslate(layout, keyCode, UInt16(kUCKeyActionDown), carbonModifiers,
                                  UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysBit),
                                  &deadKeyState, chars.count, &length, &chars)
        }
        guard status == noErr, length == 1, let scalar = Unicode.Scalar(chars[0]), scalar.value >= 0x20 else { return nil }
        return Character(scalar)
    }

    /// True when the layout types ASCII letters, i.e. its printed labels are Latin.
    public var typesLatin: Bool {
        character(keyCode: PhysicalKey.a.rawValue)?.isASCII == true
    }
}

public enum KeyLabels {
    /// What to print for a binding in menus and the cheat sheet: letters and digits as the user's layout
    /// labels that key (or the ASCII-capable layout when the layout is non-Latin); punctuation bindings as the
    /// character itself, since that is what the user presses on their Latin layout.
    @MainActor public static func label(for spec: KeySpec, layout: KeyLayout? = nil) -> String {
        switch spec {
        case .character(let c):
            return String(c)
        case .position(let key):
            switch key {
            case .space, .return, .tab, .delete, .escape, .leftArrow, .rightArrow, .upArrow, .downArrow:
                return key.usLabel
            default:
                let chosen = layout ?? KeyLayout.current()
                let source = (chosen?.typesLatin == true) ? chosen : (KeyLayout.asciiCapable() ?? chosen)
                return source?.character(keyCode: key.rawValue).map { String($0).uppercased() } ?? key.usLabel
            }
        }
    }

    public static func label(for modifiers: KeyModifiers) -> String {
        (modifiers.contains(.control) ? "⌃" : "") + (modifiers.contains(.option) ? "⌥" : "")
            + (modifiers.contains(.shift) ? "⇧" : "") + (modifiers.contains(.command) ? "⌘" : "")
    }
}

extension KeyInput {
    /// Reduces a key-down or key-up `NSEvent`. `layout` resolves the character for punctuation bindings;
    /// pass the ASCII-capable layout.
    public init?(event: NSEvent, layout: KeyLayout?) {
        guard event.type == .keyDown || event.type == .keyUp else { return nil }
        var mods: KeyModifiers = []
        let flags = event.modifierFlags
        if flags.contains(.shift) { mods.insert(.shift) }
        if flags.contains(.control) { mods.insert(.control) }
        if flags.contains(.option) { mods.insert(.option) }
        if flags.contains(.command) { mods.insert(.command) }
        self.init(keyCode: event.keyCode, modifiers: mods, isDown: event.type == .keyDown,
                  isRepeat: event.type == .keyDown && event.isARepeat, timestamp: event.timestamp,
                  character: layout?.character(keyCode: event.keyCode, shift: mods.contains(.shift),
                                               option: mods.contains(.option)))
    }
}
