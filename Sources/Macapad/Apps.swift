import AppKit
import Hummingbird

struct AppInfo: Codable, Sendable {
    var name: String
    var bundleId: String
    var path: String
}

struct AppList: Codable, Sendable, ResponseEncodable {
    var apps: [AppInfo]
}

struct ShortcutList: Codable, Sendable, ResponseEncodable {
    var shortcuts: [String]
}

/// Installed apps and their icons, plus the user's Shortcuts.app shortcuts.
enum Apps {
    private static let roots: [URL] = [
        "/Applications",
        "/Applications/Utilities",
        "/System/Applications",
        "/System/Applications/Utilities",
        NSHomeDirectory() + "/Applications",
    ].map { URL(fileURLWithPath: $0) } + [
        URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app"),
    ]

    /// Every .app in the usual folders (one level of subfolders too, for suites
    /// like "Microsoft Office/…"), deduped by bundle id and sorted by name.
    static func list() -> [AppInfo] {
        var seen = Set<String>()
        var apps: [AppInfo] = []
        for url in roots.flatMap(appBundles(in:)) {
            guard let id = Bundle(url: url)?.bundleIdentifier, seen.insert(id).inserted else { continue }
            let name = FileManager.default.displayName(atPath: url.path)
                .replacingOccurrences(of: #"\.app$"#, with: "", options: .regularExpression)
            apps.append(AppInfo(name: name, bundleId: id, path: url.path))
        }
        return apps.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private static func appBundles(in root: URL) -> [URL] {
        if root.pathExtension == "app" { return [root] }
        let fm = FileManager.default
        let children = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: .skipsHiddenFiles)) ?? []
        return children.flatMap { child -> [URL] in
            if child.pathExtension == "app" { return [child] }
            guard (try? child.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { return [] }
            let nested = (try? fm.contentsOfDirectory(at: child, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? []
            return nested.filter { $0.pathExtension == "app" }
        }
    }

    // MARK: Icons

    private static let iconLock = NSLock()
    nonisolated(unsafe) private static var iconCache: [String: Data] = [:]

    /// The app's icon as a square PNG (size in pixels), or nil for an unknown bundle id.
    @MainActor
    static func iconPNG(bundleId: String, size: Int) -> Data? {
        let key = "\(bundleId)@\(size)"
        if let cached = iconLock.withLock({ iconCache[key] }) { return cached }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) else { return nil }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        icon.draw(in: NSRect(x: 0, y: 0, width: size, height: size))
        NSGraphicsContext.restoreGraphicsState()
        guard let png = rep.representation(using: .png, properties: [:]) else { return nil }
        iconLock.withLock { iconCache[key] = png }
        return png
    }

    // MARK: Shortcuts.app

    /// Names of the user's shortcuts, as `shortcuts list` prints them.
    static func shortcuts() async -> [String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
        process.arguments = ["list"]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return [] }
        let data = await Task.detached { out.fileHandleForReading.readDataToEndOfFile() }.value
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }
}
