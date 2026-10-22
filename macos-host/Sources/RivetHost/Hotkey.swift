import Carbon.HIToolbox

/// One hotkey grammar shared with the backend (settings.rkt) and the
/// Windows/Linux hosts: one or more modifiers (alt/ctrl/shift/cmd/win/
/// super) then a key — space, a-z, 0-9, f1-f12, comma, period, minus,
/// equal, tab. Both hosts parse the same spec so a setting written on one
/// platform binds on all three.
enum Hotkey {
    struct CarbonBinding {
        let keyCode: UInt32
        let modifiers: UInt32
    }

    /// Carbon (modifier mask, key code) for a spec, or nil when the spec
    /// does not parse — callers keep the previous binding in that case.
    static func parse(_ spec: String) -> CarbonBinding? {
        var modifiers: UInt32 = 0
        var keyToken: String?
        for token in spec.lowercased().split(separator: "+") {
            switch token {
            case "alt", "option": modifiers |= UInt32(optionKey)
            case "ctrl", "control": modifiers |= UInt32(controlKey)
            case "shift": modifiers |= UInt32(shiftKey)
            case "cmd", "win", "super": modifiers |= UInt32(cmdKey)
            default:
                if keyToken != nil { return nil }
                keyToken = String(token)
            }
        }
        guard let key = keyToken, modifiers != 0,
              let keyCode = keyCode(for: key) else { return nil }
        return CarbonBinding(keyCode: keyCode, modifiers: modifiers)
    }

    /// Human-readable form for status lines: "ctrl+shift+space" → "⌃⇧Space".
    static func display(_ spec: String) -> String {
        var symbols = ""
        var key = ""
        for token in spec.lowercased().split(separator: "+") {
            switch token {
            case "alt", "option": symbols += "⌥"
            case "ctrl", "control": symbols += "⌃"
            case "shift": symbols += "⇧"
            case "cmd", "win", "super": symbols += "⌘"
            default: key = keyDisplay(String(token))
            }
        }
        return symbols + key
    }

    private static func keyDisplay(_ key: String) -> String {
        switch key {
        case "space": return "Space"
        case "tab": return "Tab"
        case "comma": return ","
        case "period": return "."
        case "minus": return "-"
        case "equal": return "="
        default:
            if key.hasPrefix("f"), Int(key.dropFirst()) != nil { return key.uppercased() }
            return key.uppercased()
        }
    }

    private static func keyCode(for key: String) -> UInt32? {
        switch key {
        case "space": return UInt32(kVK_Space)
        case "tab": return UInt32(kVK_Tab)
        case "comma": return UInt32(kVK_ANSI_Comma)
        case "period": return UInt32(kVK_ANSI_Period)
        case "minus": return UInt32(kVK_ANSI_Minus)
        case "equal": return UInt32(kVK_ANSI_Equal)
        case "f1": return UInt32(kVK_F1)
        case "f2": return UInt32(kVK_F2)
        case "f3": return UInt32(kVK_F3)
        case "f4": return UInt32(kVK_F4)
        case "f5": return UInt32(kVK_F5)
        case "f6": return UInt32(kVK_F6)
        case "f7": return UInt32(kVK_F7)
        case "f8": return UInt32(kVK_F8)
        case "f9": return UInt32(kVK_F9)
        case "f10": return UInt32(kVK_F10)
        case "f11": return UInt32(kVK_F11)
        case "f12": return UInt32(kVK_F12)
        default: break
        }
        if key.count == 1, let c = key.first {
            if let letter = letterKeyCodes[String(c.uppercased())] {
                return UInt32(letter)
            }
            if c.isNumber, let digit = digitKeyCodes[String(c)] {
                return UInt32(digit)
            }
        }
        return nil
    }

    // Recording: Carbon keycode + modifier mask back to the shared spec
    // grammar. Only specs that round-trip through parse() are offered — a
    // recording the grammar refuses is a bug, not a user error.
    static func spec(forKeyCode code: UInt32, modifiers mask: UInt32) -> String? {
        var parts: [String] = []
        if mask & UInt32(controlKey) != 0 { parts.append("ctrl") }
        if mask & UInt32(optionKey) != 0 { parts.append("alt") }
        if mask & UInt32(shiftKey) != 0 { parts.append("shift") }
        if mask & UInt32(cmdKey) != 0 { parts.append("cmd") }
        guard let key = keyName(forKeyCode: code) else { return nil }
        parts.append(key)
        return parts.joined(separator: "+")
    }

    private static func keyName(forKeyCode code: UInt32) -> String? {
        if let named = namedKeyNames.first(where: { $0.value == code }) {
            return named.key
        }
        if let letter = letterKeyCodes.first(where: { UInt32($0.value) == code }) {
            return letter.key.lowercased()
        }
        if let digit = digitKeyCodes.first(where: { UInt32($0.value) == code }) {
            return digit.key
        }
        return nil
    }

    private static let namedKeyNames: [(key: String, value: UInt32)] = [
        ("space", UInt32(kVK_Space)), ("tab", UInt32(kVK_Tab)),
        ("comma", UInt32(kVK_ANSI_Comma)), ("period", UInt32(kVK_ANSI_Period)),
        ("minus", UInt32(kVK_ANSI_Minus)), ("equal", UInt32(kVK_ANSI_Equal)),
        ("f1", UInt32(kVK_F1)), ("f2", UInt32(kVK_F2)), ("f3", UInt32(kVK_F3)),
        ("f4", UInt32(kVK_F4)), ("f5", UInt32(kVK_F5)), ("f6", UInt32(kVK_F6)),
        ("f7", UInt32(kVK_F7)), ("f8", UInt32(kVK_F8)), ("f9", UInt32(kVK_F9)),
        ("f10", UInt32(kVK_F10)), ("f11", UInt32(kVK_F11)), ("f12", UInt32(kVK_F12))
    ]

    // The ANSI key codes are layout history, not a sequence: table them.
    private static let letterKeyCodes: [String: Int] = [
        "A": kVK_ANSI_A, "S": kVK_ANSI_S, "D": kVK_ANSI_D, "F": kVK_ANSI_F,
        "H": kVK_ANSI_H, "G": kVK_ANSI_G, "Z": kVK_ANSI_Z, "X": kVK_ANSI_X,
        "C": kVK_ANSI_C, "V": kVK_ANSI_V, "B": kVK_ANSI_B, "Q": kVK_ANSI_Q,
        "W": kVK_ANSI_W, "E": kVK_ANSI_E, "R": kVK_ANSI_R, "Y": kVK_ANSI_Y,
        "T": kVK_ANSI_T, "O": kVK_ANSI_O, "U": kVK_ANSI_U, "I": kVK_ANSI_I,
        "P": kVK_ANSI_P, "L": kVK_ANSI_L, "J": kVK_ANSI_J, "K": kVK_ANSI_K,
        "N": kVK_ANSI_N, "M": kVK_ANSI_M
    ]

    private static let digitKeyCodes: [String: Int] = [
        "1": kVK_ANSI_1, "2": kVK_ANSI_2, "3": kVK_ANSI_3, "4": kVK_ANSI_4,
        "5": kVK_ANSI_5, "6": kVK_ANSI_6, "7": kVK_ANSI_7, "8": kVK_ANSI_8,
        "9": kVK_ANSI_9, "0": kVK_ANSI_0
    ]
}
