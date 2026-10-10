import AppKit
import Carbon.HIToolbox
import CoreGraphics

enum InputError: LocalizedError {
    case unknownKey(String)
    case noKey(String)
    case eventFailed

    var errorDescription: String? {
        switch self {
        case .unknownKey(let k): return "Unknown key '\(k)'"
        case .noKey(let combo): return "Shortcut '\(combo)' has no key, only modifiers"
        case .eventFailed: return "Could not create keyboard event"
        }
    }
}

/// Synthesises keyboard and media-key events. Requires Accessibility permission.
enum Input {
    static var hasPermission: Bool { CGPreflightPostEventAccess() }

    @discardableResult
    static func requestPermission() -> Bool { CGRequestPostEventAccess() }

    // MARK: Media keys

    /// Posts the same system-defined event the keyboard's media keys send,
    /// so it controls whatever app currently owns "Now Playing".
    static func press(_ key: MediaKey) {
        let code: Int32 = switch key {
        case .playPause: NX_KEYTYPE_PLAY
        case .next: NX_KEYTYPE_NEXT
        case .previous: NX_KEYTYPE_PREVIOUS
        case .volumeUp: NX_KEYTYPE_SOUND_UP
        case .volumeDown: NX_KEYTYPE_SOUND_DOWN
        case .mute: NX_KEYTYPE_MUTE
        }
        for down in [true, false] {
            let state: Int32 = down ? 0xA : 0xB
            let event = NSEvent.otherEvent(
                with: .systemDefined,
                location: .zero,
                modifierFlags: NSEvent.ModifierFlags(rawValue: UInt(state << 8)),
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                subtype: 8,
                data1: Int((code << 16) | (state << 8)),
                data2: -1
            )
            event?.cgEvent?.post(tap: .cghidEventTap)
        }
    }

    // MARK: Keyboard shortcuts

    /// Sends a shortcut such as "cmd+shift+t", "ctrl+left" or "f5".
    static func keystroke(_ combo: String) throws {
        var flags: CGEventFlags = []
        var keyCode: CGKeyCode?
        var text = combo.lowercased().replacingOccurrences(of: " ", with: "")
        // A trailing "+" key ("cmd++") is shift+= on ANSI keyboards.
        if text == "+" || text.hasSuffix("++") {
            flags.insert(.maskShift)
            text = String(text.dropLast()) + "="
        }
        for part in text.split(separator: "+").map(String.init) {
            if let mod = modifiers[part] {
                flags.insert(mod)
            } else if let code = keyCodes[part] {
                keyCode = code
            } else {
                throw InputError.unknownKey(part)
            }
        }
        guard let keyCode else { throw InputError.noKey(combo) }
        let source = CGEventSource(stateID: .hidSystemState)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        else { throw InputError.eventFailed }
        down.flags = flags
        up.flags = flags
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }

    /// Types arbitrary text (any language/emoji) regardless of keyboard layout.
    static func type(_ text: String) throws {
        let source = CGEventSource(stateID: .hidSystemState)
        let units = Array(text.utf16)
        // CGEvent carries at most 20 UTF-16 units per event.
        for start in stride(from: 0, to: units.count, by: 20) {
            var chunk = Array(units[start..<min(start + 20, units.count)])
            guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
                  let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
            else { throw InputError.eventFailed }
            down.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: &chunk)
            up.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: &chunk)
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
        }
    }

    private static let modifiers: [String: CGEventFlags] = [
        "cmd": .maskCommand, "command": .maskCommand, "⌘": .maskCommand,
        "shift": .maskShift, "⇧": .maskShift,
        "opt": .maskAlternate, "option": .maskAlternate, "alt": .maskAlternate, "⌥": .maskAlternate,
        "ctrl": .maskControl, "control": .maskControl, "⌃": .maskControl,
        "fn": .maskSecondaryFn,
    ]

    /// Physical key positions (ANSI layout).
    private static let keyCodes: [String: CGKeyCode] = {
        var map: [String: Int] = [
            "a": kVK_ANSI_A, "b": kVK_ANSI_B, "c": kVK_ANSI_C, "d": kVK_ANSI_D, "e": kVK_ANSI_E,
            "f": kVK_ANSI_F, "g": kVK_ANSI_G, "h": kVK_ANSI_H, "i": kVK_ANSI_I, "j": kVK_ANSI_J,
            "k": kVK_ANSI_K, "l": kVK_ANSI_L, "m": kVK_ANSI_M, "n": kVK_ANSI_N, "o": kVK_ANSI_O,
            "p": kVK_ANSI_P, "q": kVK_ANSI_Q, "r": kVK_ANSI_R, "s": kVK_ANSI_S, "t": kVK_ANSI_T,
            "u": kVK_ANSI_U, "v": kVK_ANSI_V, "w": kVK_ANSI_W, "x": kVK_ANSI_X, "y": kVK_ANSI_Y,
            "z": kVK_ANSI_Z,
            "0": kVK_ANSI_0, "1": kVK_ANSI_1, "2": kVK_ANSI_2, "3": kVK_ANSI_3, "4": kVK_ANSI_4,
            "5": kVK_ANSI_5, "6": kVK_ANSI_6, "7": kVK_ANSI_7, "8": kVK_ANSI_8, "9": kVK_ANSI_9,
            "-": kVK_ANSI_Minus, "=": kVK_ANSI_Equal, "[": kVK_ANSI_LeftBracket, "]": kVK_ANSI_RightBracket,
            "\\": kVK_ANSI_Backslash, ";": kVK_ANSI_Semicolon, "'": kVK_ANSI_Quote, ",": kVK_ANSI_Comma,
            ".": kVK_ANSI_Period, "/": kVK_ANSI_Slash, "`": kVK_ANSI_Grave,
            "return": kVK_Return, "enter": kVK_Return, "tab": kVK_Tab, "space": kVK_Space,
            "delete": kVK_Delete, "backspace": kVK_Delete, "forwarddelete": kVK_ForwardDelete,
            "escape": kVK_Escape, "esc": kVK_Escape,
            "left": kVK_LeftArrow, "right": kVK_RightArrow, "up": kVK_UpArrow, "down": kVK_DownArrow,
            "home": kVK_Home, "end": kVK_End, "pageup": kVK_PageUp, "pagedown": kVK_PageDown,
        ]
        let fKeys = [kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10,
                     kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20]
        for (i, code) in fKeys.enumerated() { map["f\(i + 1)"] = code }
        return map.mapValues { CGKeyCode($0) }
    }()
}
