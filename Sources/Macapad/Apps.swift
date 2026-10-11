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
        guard let png = squarePNG(NSWorkspace.shared.icon(forFile: url.path), size: size) else { return nil }
        iconLock.withLock { iconCache[key] = png }
        return png
    }

    /// An image drawn into a size × size PNG.
    @MainActor
    private static func squarePNG(_ image: NSImage, size: Int) -> Data? {
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(x: 0, y: 0, width: size, height: size))
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
    }

    // MARK: Website icons

    /// Hosts that had no icon, so they aren't looked up again this run.
    nonisolated(unsafe) private static var noWebIcon = Set<String>()

    /// A website's icon (its favicon) as a square PNG, or nil when none can be found. From Google's
    /// favicon service first (it finds the icon a page declares, not just /favicon.ico), then the
    /// site's own /favicon.ico. Frontends cache these; `GET /api/web/icon` serves them.
    static func webIconPNG(host: String, size: Int) async -> Data? {
        let key = "web:\(host)@\(size)"
        if let cached = iconLock.withLock({ iconCache[key] }) { return cached }
        if iconLock.withLock({ noWebIcon.contains(host) }) { return nil }
        let sources = [
            "https://www.google.com/s2/favicons?domain=\(host)&sz=\(max(size, 64))",
            "https://\(host)/favicon.ico",
        ]
        for source in sources {
            guard let url = URL(string: source) else { continue }
            var request = URLRequest(url: url)
            request.timeoutInterval = 8
            guard let (data, response) = try? await URLSession.shared.data(for: request),
                  (response as? HTTPURLResponse)?.statusCode == 200, !data.isEmpty,
                  let image = NSImage(data: data), image.isValid else { continue }
            guard let png = await MainActor.run(body: { squarePNG(image, size: size) }) else { continue }
            iconLock.withLock { iconCache[key] = png }
            return png
        }
        iconLock.withLock { _ = noWebIcon.insert(host) }
        return nil
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
