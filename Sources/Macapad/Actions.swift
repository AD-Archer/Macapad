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

    private static func media(_ id: String, _ name: String, _ icon: String, _ key: MediaKey, category: String = "media") -> MacAction {
        MacAction(id: id, name: name, icon: icon, category: category, steps: [.media(key)])
    }

    private static func window(_ id: String, _ name: String, _ icon: String, _ to: WindowPlacement) -> MacAction {
        MacAction(id: id, name: name, icon: icon, category: "windows", steps: [.window(to)])
    }

    private static func toggle(_ id: String, _ name: String, _ icon: String, _ setting: SystemSetting) -> MacAction {
        MacAction(id: id, name: name, icon: icon, category: "system", steps: [.toggle(setting, on: nil)])
    }

    private static func script(_ id: String, _ name: String, _ icon: String, _ source: String) -> MacAction {
        MacAction(id: id, name: name, icon: icon, category: "system", steps: [.appleScript(source)])
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

        MacAction(id: "keep-awake", name: "Keep Mac awake", icon: "coffee", category: "system", steps: [.keepAwake(on: nil, minutes: nil)]),
        MacAction(id: "jiggler", name: "Mouse jiggler", icon: "mouse", category: "system", steps: [.jiggler(on: nil, minutes: nil)]),
        MacAction(id: "siri", name: "Siri", icon: "mic", category: "system", steps: [.openApp("com.apple.siri.launcher")]),
        media("brightness-up", "Brightness up", "brightness_high", .brightnessUp, category: "system"),
        media("brightness-down", "Brightness down", "brightness_low", .brightnessDown, category: "system"),
        toggle("dark-mode", "Dark mode", "dark_mode", .darkMode),
        toggle("wifi", "Wi-Fi on/off", "wifi", .wifi),
        toggle("bluetooth", "Bluetooth on/off", "bluetooth", .bluetooth),
        toggle("stage-manager", "Stage Manager", "view_sidebar", .stageManager),
        toggle("hidden-files", "Show hidden files", "visibility", .hiddenFiles),
        script("empty-trash", "Empty Trash", "delete", "tell application \"Finder\" to empty trash"),
        script("eject-disks", "Eject all disks", "eject", "tell application \"Finder\" to eject (every disk whose ejectable is true)"),
        script("sleep-display", "Turn off display", "desktop_access_disabled", "do shell script \"pmset displaysleepnow\""),
        script("sleep", "Sleep", "bedtime", "do shell script \"pmset sleepnow\""),
        // System Events asks apps to quit first, so unsaved work still gets its "Save?" prompt.
        script("restart", "Restart", "restart_alt", "tell application \"System Events\" to restart"),
        script("shut-down", "Shut down", "power_settings_new", "tell application \"System Events\" to shut down"),
        MacAction(id: "screen-saver", name: "Screen saver", icon: "wallpaper", category: "system", steps: [.openApp("com.apple.ScreenSaver.Engine")]),
        keys("show-desktop", "Show desktop", "desktop_windows", "system", "f11"),
        keys("force-quit", "Force quit…", "cancel", "system", "cmd+opt+esc"),

        keys("accessibility-shortcuts", "Accessibility shortcuts", "accessibility_new", "accessibility", "opt+cmd+f5"),
        keys("voiceover", "VoiceOver", "record_voice_over", "accessibility", "cmd+f5"),
        keys("zoom", "Zoom", "zoom_in", "accessibility", "opt+cmd+8"),
        keys("zoom-in", "Zoom in", "zoom_in", "accessibility", "opt+cmd+="),
        keys("zoom-out", "Zoom out", "zoom_out", "accessibility", "opt+cmd+-"),
        keys("invert-colors", "Invert colors", "invert_colors", "accessibility", "ctrl+opt+cmd+8"),
        keys("speak-selection", "Speak selection", "text_to_speech", "accessibility", "opt+esc"),

        keys("minimize", "Minimise window", "arrow_downward", "windows", "cmd+m"),
        keys("fullscreen", "Toggle full screen", "open_in_new", "windows", "ctrl+cmd+f"),
        keys("close-window", "Close window", "close", "windows", "cmd+shift+w"),
        keys("next-window", "Next window of app", "refresh", "windows", "cmd+`"),
        keys("hide-app", "Hide app", "remove_circle_outline", "windows", "cmd+h"),
        keys("quit-app", "Quit app", "power_settings_new", "windows", "cmd+q"),
        window("window-left", "Left half", "splitscreen_left", .left),
        window("window-right", "Right half", "splitscreen_right", .right),
        window("window-top", "Top half", "splitscreen_top", .top),
        window("window-bottom", "Bottom half", "splitscreen_bottom", .bottom),
        window("window-top-left", "Top-left quarter", "north_west", .topLeft),
        window("window-top-right", "Top-right quarter", "north_east", .topRight),
        window("window-bottom-left", "Bottom-left quarter", "south_west", .bottomLeft),
        window("window-bottom-right", "Bottom-right quarter", "south_east", .bottomRight),
        window("window-maximize", "Fill screen", "fit_screen", .maximize),
        window("window-center", "Center window", "filter_center_focus", .center),
        window("window-next-display", "Move to next display", "monitor", .nextDisplay),
        window("window-restore", "Restore size", "restore", .restore),

        MacAction(id: "left-click", name: "Click", icon: "left_click", category: "mouse", steps: [.click(.left, count: 1)]),
        MacAction(id: "right-click", name: "Right-click", icon: "right_click", category: "mouse", steps: [.click(.right, count: 1)]),

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
