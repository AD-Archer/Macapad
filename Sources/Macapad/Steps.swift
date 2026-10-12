import Foundation

enum MediaKey: String, Codable, Sendable, CaseIterable {
    case playPause, next, previous, volumeUp, volumeDown, mute, brightnessUp, brightnessDown
}

enum MouseButton: String, Codable, Sendable, CaseIterable {
    case left, right, middle
}

/// Where a `window` step puts the front window.
enum WindowPlacement: String, Codable, Sendable, CaseIterable {
    case left, right, top, bottom
    case topLeft = "top-left", topRight = "top-right", bottomLeft = "bottom-left", bottomRight = "bottom-right"
    case leftThird = "left-third", centerThird = "center-third", rightThird = "right-third"
    case leftTwoThirds = "left-two-thirds", rightTwoThirds = "right-two-thirds"
    case maximize, center
    case nextDisplay = "next-display"
    case restore
}

/// One thing a button does. Encoded as `{"type": "...", ...fields}`.
enum Step: Sendable {
    case media(MediaKey)
    case keystroke(String)
    case typeText(String)
    case openURL(String)
    case openApp(String)
    case shortcut(String)
    case appleScript(String)
    case wait(Int)
    /// Runs a built-in or custom action by id (see Actions.swift).
    case action(String)
    case window(WindowPlacement)
    /// `on` nil toggles; `minutes` nil lasts until turned off.
    case keepAwake(on: Bool?, minutes: Int?)
    case jiggler(on: Bool?, minutes: Int?)
    case click(MouseButton, count: Int)
    /// Lines; positive dy shows content further down.
    case scroll(dx: Int, dy: Int)
    case moveMouse(dx: Int, dy: Int)
    /// `on` nil flips it.
    case toggle(SystemSetting, on: Bool?)
}

extension Step: Codable {
    private enum CodingKeys: String, CodingKey {
        case type, key, keys, text, url, app, name, source, ms, id, to, on, minutes, button, count, dx, dy, setting
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let type = try c.decode(String.self, forKey: .type)
        switch type {
        case "media": self = .media(try c.decode(MediaKey.self, forKey: .key))
        case "keystroke": self = .keystroke(try c.decode(String.self, forKey: .keys))
        case "typeText": self = .typeText(try c.decode(String.self, forKey: .text))
        case "openURL": self = .openURL(try c.decode(String.self, forKey: .url))
        case "openApp": self = .openApp(try c.decode(String.self, forKey: .app))
        case "shortcut": self = .shortcut(try c.decode(String.self, forKey: .name))
        case "appleScript": self = .appleScript(try c.decode(String.self, forKey: .source))
        case "wait": self = .wait(try c.decode(Int.self, forKey: .ms))
        case "action": self = .action(try c.decode(String.self, forKey: .id))
        case "window": self = .window(try c.decode(WindowPlacement.self, forKey: .to))
        case "keepAwake":
            self = .keepAwake(on: try c.decodeIfPresent(Bool.self, forKey: .on), minutes: try c.decodeIfPresent(Int.self, forKey: .minutes))
        case "jiggler":
            self = .jiggler(on: try c.decodeIfPresent(Bool.self, forKey: .on), minutes: try c.decodeIfPresent(Int.self, forKey: .minutes))
        case "click":
            self = .click(try c.decodeIfPresent(MouseButton.self, forKey: .button) ?? .left,
                          count: try c.decodeIfPresent(Int.self, forKey: .count) ?? 1)
        case "scroll":
            self = .scroll(dx: try c.decodeIfPresent(Int.self, forKey: .dx) ?? 0, dy: try c.decodeIfPresent(Int.self, forKey: .dy) ?? 0)
        case "toggle":
            self = .toggle(try c.decode(SystemSetting.self, forKey: .setting), on: try c.decodeIfPresent(Bool.self, forKey: .on))
        case "moveMouse":
            self = .moveMouse(dx: try c.decodeIfPresent(Int.self, forKey: .dx) ?? 0, dy: try c.decodeIfPresent(Int.self, forKey: .dy) ?? 0)
        default:
            throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "Unknown step type '\(type)'")
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .media(let key): try c.encode("media", forKey: .type); try c.encode(key, forKey: .key)
        case .keystroke(let keys): try c.encode("keystroke", forKey: .type); try c.encode(keys, forKey: .keys)
        case .typeText(let text): try c.encode("typeText", forKey: .type); try c.encode(text, forKey: .text)
        case .openURL(let url): try c.encode("openURL", forKey: .type); try c.encode(url, forKey: .url)
        case .openApp(let app): try c.encode("openApp", forKey: .type); try c.encode(app, forKey: .app)
        case .shortcut(let name): try c.encode("shortcut", forKey: .type); try c.encode(name, forKey: .name)
        case .appleScript(let source): try c.encode("appleScript", forKey: .type); try c.encode(source, forKey: .source)
        case .wait(let ms): try c.encode("wait", forKey: .type); try c.encode(ms, forKey: .ms)
        case .action(let id): try c.encode("action", forKey: .type); try c.encode(id, forKey: .id)
        case .window(let to): try c.encode("window", forKey: .type); try c.encode(to, forKey: .to)
        case .keepAwake(let on, let minutes), .jiggler(let on, let minutes):
            if case .keepAwake = self { try c.encode("keepAwake", forKey: .type) } else { try c.encode("jiggler", forKey: .type) }
            try c.encodeIfPresent(on, forKey: .on)
            try c.encodeIfPresent(minutes, forKey: .minutes)
        case .click(let button, let count):
            try c.encode("click", forKey: .type); try c.encode(button, forKey: .button); try c.encode(count, forKey: .count)
        case .toggle(let setting, let on):
            try c.encode("toggle", forKey: .type); try c.encode(setting, forKey: .setting); try c.encodeIfPresent(on, forKey: .on)
        case .scroll(let dx, let dy), .moveMouse(let dx, let dy):
            if case .scroll = self { try c.encode("scroll", forKey: .type) } else { try c.encode("moveMouse", forKey: .type) }
            try c.encode(dx, forKey: .dx); try c.encode(dy, forKey: .dy)
        }
    }
}
