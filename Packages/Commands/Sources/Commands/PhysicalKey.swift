/// A key identified by where it sits, not by what it types: the ANSI virtual key codes behind `NSEvent.keyCode`.
/// They do not change with the input source, so `X` is the same key under Greek, Russian or Japanese input.
public enum PhysicalKey: UInt16, CaseIterable, Sendable {
    case a = 0, s = 1, d = 2, f = 3, h = 4, g = 5, z = 6, x = 7, c = 8, v = 9, b = 11
    case q = 12, w = 13, e = 14, r = 15, y = 16, t = 17
    case digit1 = 18, digit2 = 19, digit3 = 20, digit4 = 21, digit6 = 22, digit5 = 23
    case digit9 = 25, digit7 = 26, digit8 = 28, digit0 = 29
    case o = 31, u = 32, i = 34, p = 35, l = 37, j = 38, k = 40, n = 45, m = 46
    case equal = 24, minus = 27, rightBracket = 30, leftBracket = 33, quote = 39, semicolon = 41
    case backslash = 42, comma = 43, slash = 44, period = 47, grave = 50
    case `return` = 36, tab = 48, space = 49, delete = 51, escape = 53
    case leftArrow = 123, rightArrow = 124, downArrow = 125, upArrow = 126

    /// The ASCII label printed on a US keyboard, used when no layout can be asked.
    public var usLabel: String {
        switch self {
        case .digit0: "0"
        case .digit1: "1"
        case .digit2: "2"
        case .digit3: "3"
        case .digit4: "4"
        case .digit5: "5"
        case .digit6: "6"
        case .digit7: "7"
        case .digit8: "8"
        case .digit9: "9"
        case .equal: "="
        case .minus: "-"
        case .rightBracket: "]"
        case .leftBracket: "["
        case .quote: "'"
        case .semicolon: ";"
        case .backslash: "\\"
        case .comma: ","
        case .slash: "/"
        case .period: "."
        case .grave: "`"
        case .return: "↩"
        case .tab: "⇥"
        case .space: "Space"
        case .delete: "⌫"
        case .escape: "⎋"
        case .leftArrow: "←"
        case .rightArrow: "→"
        case .downArrow: "↓"
        case .upArrow: "↑"
        default: String(describing: self).uppercased()
        }
    }
}
