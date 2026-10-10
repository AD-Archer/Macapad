import Foundation
import Hummingbird

/// The whole button layout, stored in ~/.macapad/deck.json.
struct Deck: Codable, Sendable, ResponseEncodable {
    var version: Int = 1
    var pages: [Page]
}

/// A grid of buttons. Folder pages are hidden from the swipeable page row
/// and are only reachable from a button that links to them.
struct Page: Codable, Sendable {
    var id: String
    var name: String
    var columns: Int?
    var folder: Bool?
    var buttons: [DeckButton]
}

struct DeckButton: Codable, Sendable {
    var id: String
    var label: String
    var icon: String?
    var color: String?
    /// Steps run in order when the button is pressed.
    var steps: [Step]
    /// If set, pressing the button opens this page (a folder) instead of running steps.
    var page: String?
}

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

extension Deck {
    func button(id: String) -> DeckButton? {
        for page in pages {
            if let b = page.buttons.first(where: { $0.id == id }) { return b }
        }
        return nil
    }

    /// Returns a human-readable problem, or nil if the deck is valid.
    func validationError() -> String? {
        if pages.isEmpty { return "Deck needs at least one page" }
        var pageIDs = Set<String>()
        for page in pages {
            if page.id.isEmpty { return "A page has an empty id" }
            if !pageIDs.insert(page.id).inserted { return "Duplicate page id '\(page.id)'" }
        }
        if !pages.contains(where: { $0.folder != true }) { return "Deck needs at least one non-folder page" }
        var buttonIDs = Set<String>()
        for page in pages {
            for b in page.buttons {
                if b.id.isEmpty { return "A button on '\(page.name)' has an empty id" }
                if !buttonIDs.insert(b.id).inserted { return "Duplicate button id '\(b.id)'" }
                if let target = b.page, !pageIDs.contains(target) {
                    return "Button '\(b.label)' links to missing page '\(target)'"
                }
            }
        }
        return nil
    }

    static let starter = Deck(pages: [
        Page(id: "main", name: "Main", columns: nil, folder: nil, buttons: [
            DeckButton(id: "prev", label: "Previous", icon: "⏮", color: nil, steps: [.media(.previous)]),
            DeckButton(id: "playpause", label: "Play / Pause", icon: "⏯", color: "#1db954", steps: [.media(.playPause)]),
            DeckButton(id: "next", label: "Next", icon: "⏭", color: nil, steps: [.media(.next)]),
            DeckButton(id: "voldown", label: "Vol −", icon: "🔉", color: nil, steps: [.media(.volumeDown)]),
            DeckButton(id: "volup", label: "Vol +", icon: "🔊", color: nil, steps: [.media(.volumeUp)]),
            DeckButton(id: "mute", label: "Mute", icon: "🔇", color: nil, steps: [.media(.mute)]),
            DeckButton(id: "newtab", label: "New tab", icon: "➕", color: nil, steps: [.keystroke("cmd+t")]),
            DeckButton(id: "closetab", label: "Close tab", icon: "✖️", color: nil, steps: [.keystroke("cmd+w")]),
            DeckButton(id: "reopentab", label: "Reopen tab", icon: "↩️", color: nil, steps: [.keystroke("cmd+shift+t")]),
            DeckButton(id: "webfolder", label: "Sites", icon: "🌐", color: "#3b5bdb", steps: [], page: "sites"),
        ]),
        Page(id: "sites", name: "Sites", columns: nil, folder: true, buttons: [
            DeckButton(id: "hackclub", label: "Hack Club", icon: "🦕", color: "#ec3750", steps: [.openURL("https://hackclub.com")]),
            DeckButton(id: "github", label: "GitHub", icon: "🐙", color: nil, steps: [.openURL("https://github.com")]),
            DeckButton(id: "youtube", label: "YouTube", icon: "▶️", color: "#c92a2a", steps: [.openURL("https://youtube.com")]),
        ]),
    ])
}
