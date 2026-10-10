import Foundation
import Hummingbird

/// A named, reusable list of steps. Built-ins ship with the app; custom ones
/// are added through the API and saved in ~/.macapad/actions.json.
/// `icon` is a Material Symbols name, a hint for frontends.
struct MacAction: Codable, Sendable, ResponseEncodable {
    var id: String
    var name: String
    var icon: String
    var category: String
    var steps: [Step]
    /// Set in responses: false for built-ins, true for your own.
    var custom: Bool?
}

struct ActionList: Codable, Sendable, ResponseEncodable {
    var actions: [MacAction]
}

enum ActionError: LocalizedError {
    case invalid(String)

    var errorDescription: String? {
        switch self {
        case .invalid(let message): return message
        }
    }
}

final class Actions: @unchecked Sendable {
    static let shared = Actions()

    private let lock = NSLock()
    private var custom: [MacAction]
    private let fileURL = Config.directory.appendingPathComponent("actions.json")

    private init() {
        custom = (try? JSONDecoder().decode([MacAction].self, from: Data(contentsOf: fileURL))) ?? []
    }

    /// Built-ins first (in catalog order), then custom actions.
    var all: [MacAction] {
        let mine = lock.withLock { custom }
        return Self.builtin.map { var a = $0; a.custom = false; return a }
            + mine.map { var a = $0; a.custom = true; return a }
    }

    func find(_ id: String) -> MacAction? {
        Self.builtin.first { $0.id == id } ?? lock.withLock { custom.first { $0.id == id } }
    }

    /// Adds or replaces a custom action. A missing id is made from the name.
    func save(_ incoming: MacAction) throws -> MacAction {
        var action = incoming
        action.name = action.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !action.name.isEmpty else { throw ActionError.invalid("An action needs a name") }
        guard !action.steps.isEmpty else { throw ActionError.invalid("An action needs at least one step") }
        if action.id.isEmpty { action.id = Self.slug(action.name) }
        guard action.id.range(of: #"^[a-z0-9][a-z0-9-]{0,47}$"#, options: .regularExpression) != nil else {
            throw ActionError.invalid("Action ids are lowercase letters, numbers and dashes")
        }
        guard !Self.builtin.contains(where: { $0.id == action.id }) else {
            throw ActionError.invalid("'\(action.id)' is a built-in action; pick another id")
        }
        if action.icon.isEmpty { action.icon = "bolt" }
        if action.category.isEmpty { action.category = "custom" }
        action.custom = nil

        let next = lock.withLock { () -> [MacAction] in
            if let i = custom.firstIndex(where: { $0.id == action.id }) {
                custom[i] = action
            } else {
                custom.append(action)
            }
            return custom
        }
        try write(next)
        action.custom = true
        return action
    }

    /// Returns false when there was no such custom action.
    func delete(_ id: String) throws -> Bool {
        let (removed, next) = lock.withLock { () -> (Bool, [MacAction]) in
            let before = custom.count
            custom.removeAll { $0.id == id }
            return (custom.count != before, custom)
        }
        if removed { try write(next) }
        return removed
    }

    private func write(_ actions: [MacAction]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        try encoder.encode(actions).write(to: fileURL, options: .atomic)
    }

    private static func slug(_ name: String) -> String {
        let base = name.lowercased()
            .replacingOccurrences(of: #"[^a-z0-9]+"#, with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return String((base.isEmpty ? "action" : base).prefix(36)) + "-" + String(UUID().uuidString.prefix(4)).lowercased()
    }

    // MARK: Built-ins

    private static func keys(_ id: String, _ name: String, _ icon: String, _ category: String, _ combo: String) -> MacAction {
        MacAction(id: id, name: name, icon: icon, category: category, steps: [.keystroke(combo)])
    }

    private static func media(_ id: String, _ name: String, _ icon: String, _ key: MediaKey) -> MacAction {
        MacAction(id: id, name: name, icon: icon, category: "media", steps: [.media(key)])
    }

    static let builtin: [MacAction] = [
        media("play-pause", "Play / Pause", "play_pause", .playPause),
        media("next-track", "Next track", "skip_next", .next),
        media("previous-track", "Previous track", "skip_previous", .previous),
        media("volume-up", "Volume up", "volume_up", .volumeUp),
        media("volume-down", "Volume down", "volume_down", .volumeDown),
        media("mute", "Mute", "volume_off", .mute),

        keys("emoji", "Emoji & symbols", "mood", "system", "ctrl+cmd+space"),
        keys("spotlight", "Spotlight", "search", "system", "cmd+space"),
        keys("screenshot-ui", "Screenshot tools", "screenshot_monitor", "system", "cmd+shift+5"),
        keys("screenshot-area", "Screenshot area", "photo_camera", "system", "cmd+shift+4"),
        keys("screenshot-screen", "Screenshot screen", "desktop_mac", "system", "cmd+shift+3"),
        keys("mission-control", "Mission Control", "grid_view", "system", "ctrl+up"),
        keys("app-windows", "App windows", "apps", "system", "ctrl+down"),
        keys("lock-screen", "Lock screen", "lock", "system", "ctrl+cmd+q"),

        keys("minimize", "Minimise window", "arrow_downward", "windows", "cmd+m"),
        keys("fullscreen", "Toggle full screen", "open_in_new", "windows", "ctrl+cmd+f"),
        keys("close-window", "Close window", "close", "windows", "cmd+shift+w"),
        keys("next-window", "Next window of app", "refresh", "windows", "cmd+`"),
        keys("hide-app", "Hide app", "remove_circle_outline", "windows", "cmd+h"),
        keys("quit-app", "Quit app", "power_settings_new", "windows", "cmd+q"),

        keys("reload", "Reload", "refresh", "browser", "cmd+r"),
        keys("hard-reload", "Hard reload", "refresh", "browser", "cmd+shift+r"),
        keys("new-tab", "New tab", "tab", "browser", "cmd+t"),
        keys("close-tab", "Close tab", "close", "browser", "cmd+w"),
        keys("reopen-tab", "Reopen closed tab", "undo", "browser", "cmd+shift+t"),
        keys("next-tab", "Next tab", "arrow_forward", "browser", "ctrl+tab"),
        keys("previous-tab", "Previous tab", "arrow_back", "browser", "ctrl+shift+tab"),
        keys("address-bar", "Go to address bar", "link", "browser", "cmd+l"),

        keys("copy", "Copy", "content_copy", "editing", "cmd+c"),
        keys("paste", "Paste", "content_paste", "editing", "cmd+v"),
        keys("cut", "Cut", "content_cut", "editing", "cmd+x"),
        keys("undo", "Undo", "undo", "editing", "cmd+z"),
        keys("redo", "Redo", "redo", "editing", "cmd+shift+z"),
        keys("select-all", "Select all", "select_all", "editing", "cmd+a"),
        keys("find", "Find", "search", "editing", "cmd+f"),
        keys("save", "Save", "save_alt", "editing", "cmd+s"),
    ]
}
