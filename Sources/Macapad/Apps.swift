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

    /// An image drawn into a size × size PNG: the middle square of a wide or tall one (an og:image
    /// banner), never a squash.
    @MainActor
    private static func squarePNG(_ image: NSImage, size: Int) -> Data? {
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { return nil }
        let w = image.size.width, h = image.size.height, side = min(w, h)
        let from = NSRect(x: (w - side) / 2, y: (h - side) / 2, width: side, height: side)
        let to = NSRect(x: 0, y: 0, width: size, height: size)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.clear.set()
        to.fill(using: .copy)
        image.draw(in: to, from: from, operation: .sourceOver, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
    }

    // MARK: Website icons

    /// Hosts that had no icon, and when that was found out: asked again after an hour.
    nonisolated(unsafe) private static var noWebIcon: [String: Date] = [:]

    /// A website's icon as a square PNG, or nil when none can be found. The icons the site's front
    /// page declares come first (apple-touch-icon, then <link rel="icon">, then og:image), then its
    /// /favicon.ico, then Google's favicon service. Frontends cache these; `GET /api/web/icon` serves them.
    static func webIconPNG(host: String, size: Int) async -> Data? {
        let key = "web:\(host)@\(size)"
        if let cached = iconLock.withLock({ iconCache[key] }) { return cached }
        if let at = iconLock.withLock({ noWebIcon[host] }), Date().timeIntervalSince(at) < 3600 { return nil }
        var candidates = await pageIcons(host: host)
        candidates.append("https://\(host)/favicon.ico")
        candidates.append("https://www.google.com/s2/favicons?domain=\(host)&sz=\(max(size, 64))")
        for candidate in candidates {
            guard let (data, _) = await fetch(candidate), let image = NSImage(data: data), image.isValid,
                  image.size.width >= 16, image.size.height >= 16 else { continue }
            guard let png = await MainActor.run(body: { squarePNG(image, size: size) }) else { continue }
            iconLock.withLock { iconCache[key] = png }
            return png
        }
        NSLog("Macapad: no icon for \(host) (tried \(candidates.count) sources)")
        iconLock.withLock { noWebIcon[host] = Date() }
        return nil
    }

    /// One GET, following redirects: the body and the URL it ended up at. nil unless it's a 200 with a body.
    private static func fetch(_ string: String, timeout: TimeInterval = 6) async -> (Data, URL)? {
        guard let url = URL(string: string) else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X) Macapad", forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, http.statusCode == 200, !data.isEmpty else { return nil }
        return (data, http.url ?? url)
    }

    /// The icons a site's front page declares, best first: apple-touch-icon, then <link rel="icon">
    /// (the largest `sizes` first), then the Open Graph / Twitter image. As absolute URLs.
    private static func pageIcons(host: String) async -> [String] {
        guard let (data, pageURL) = await fetch("https://\(host)/") else { return [] }
        let head = data.prefix(512 * 1024)
        guard let html = String(data: head, encoding: .utf8) ?? String(data: head, encoding: .isoLatin1) else { return [] }
        var touch: [(Int, String)] = [], icons: [(Int, String)] = [], social: [String] = []
        for tag in matches(#"<(?:link|meta)\b[^>]*>"#, in: html) {
            let rel = attribute("rel", in: tag)?.lowercased() ?? ""
            let property = (attribute("property", in: tag) ?? attribute("name", in: tag))?.lowercased() ?? ""
            if rel.contains("apple-touch-icon"), let href = attribute("href", in: tag) {
                touch.append((sizeOf(tag), href))
            } else if rel.split(separator: " ").contains("icon"), let href = attribute("href", in: tag) {
                if href.lowercased().hasSuffix(".svg") { continue }  // not every SVG renders through NSImage
                icons.append((sizeOf(tag), href))
            } else if ["og:image", "og:image:url", "og:image:secure_url", "twitter:image"].contains(property),
                      let content = attribute("content", in: tag) {
                social.append(content)
            }
        }
        let ordered = touch.sorted { $0.0 > $1.0 }.map(\.1) + icons.sorted { $0.0 > $1.0 }.map(\.1) + social
        var seen = Set<String>()
        return ordered.compactMap { URL(string: $0, relativeTo: pageURL)?.absoluteString }.filter { seen.insert($0).inserted }
    }

    private static func matches(_ pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).compactMap { Range($0.range, in: text).map { String(text[$0]) } }
    }

    /// `name="value"`, `name='value'` or `name=value` inside one tag, with &amp; decoded.
    private static func attribute(_ name: String, in tag: String) -> String? {
        let pattern = "\\b\(name)\\s*=\\s*(?:\"([^\"]*)\"|'([^']*)'|([^\\s>]+))"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: tag, range: NSRange(tag.startIndex..., in: tag)) else { return nil }
        for i in 1...3 {
            if let r = Range(match.range(at: i), in: tag) {
                return String(tag[r]).replacingOccurrences(of: "&amp;", with: "&").trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    /// The first number in a `sizes="180x180"` attribute; 0 without one. "any" (an SVG) counts as big.
    private static func sizeOf(_ tag: String) -> Int {
        guard let sizes = attribute("sizes", in: tag)?.lowercased() else { return 0 }
        if sizes == "any" { return 1000 }
        return Int(sizes.split(whereSeparator: { !$0.isNumber }).first ?? "") ?? 0
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
