import Foundation

enum MediaKey: String, Codable, Sendable, CaseIterable {
    case playPause, next, previous, volumeUp, volumeDown, mute
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
}

extension Step: Codable {
    private enum CodingKeys: String, CodingKey {
        case type, key, keys, text, url, app, name, source, ms
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
        }
    }
}
