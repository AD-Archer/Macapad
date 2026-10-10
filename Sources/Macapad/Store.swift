import Foundation

/// Owns the deck file and API token on disk, and reloads the deck when it is edited by hand.
final class Store: @unchecked Sendable {
    static let directory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".macapad")
    static let deckURL = directory.appendingPathComponent("deck.json")
    static let tokenURL = directory.appendingPathComponent("token")

    private let lock = NSLock()
    private var _deck: Deck
    private var lastWrite: Data?
    private var watcher: DispatchSourceFileSystemObject?
    private var fileWatcher: DispatchSourceFileSystemObject?

    let token: String
    /// Called (on a background queue) whenever the deck changes, from the API or a hand edit.
    var onChange: (@Sendable (Deck) -> Void)?

    var deck: Deck { lock.withLock { _deck } }

    init() throws {
        try FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        token = try Self.loadOrCreateToken()
        if FileManager.default.fileExists(atPath: Self.deckURL.path) {
            _deck = try Self.readDeck()
        } else {
            _deck = Deck.starter
            try write(Deck.starter)
        }
        watch()
    }

    func save(_ deck: Deck) throws {
        try write(deck)
        lock.withLock { _deck = deck }
        onChange?(deck)
    }

    private func write(_ deck: Deck) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        let data = try encoder.encode(deck)
        lock.withLock { lastWrite = data }
        try data.write(to: Self.deckURL, options: .atomic)
    }

    private static func readDeck() throws -> Deck {
        try JSONDecoder().decode(Deck.self, from: Data(contentsOf: deckURL))
    }

    private static func loadOrCreateToken() throws -> String {
        if let existing = try? String(contentsOf: tokenURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines), !existing.isEmpty {
            return existing
        }
        var bytes = [UInt8](repeating: 0, count: 24)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw CocoaError(.fileWriteUnknown)
        }
        let token = bytes.map { String(format: "%02x", $0) }.joined()
        try token.write(to: tokenURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tokenURL.path)
        return token
    }

    /// Watches both the folder (editors that save by replacing the file) and the file itself
    /// (tools that write in place). Replacing the file means re-attaching the file watcher.
    private func watch() {
        let queue = DispatchQueue(label: "macapad.store.watch")
        watcher = makeSource(path: Self.directory.path, events: .write, queue: queue) { [weak self] _ in
            self?.watchFile(queue: queue)
            self?.reloadFromDisk()
        }
        watchFile(queue: queue)
    }

    private func watchFile(queue: DispatchQueue) {
        fileWatcher?.cancel()
        fileWatcher = makeSource(path: Self.deckURL.path, events: [.write, .extend, .delete, .rename], queue: queue) { [weak self] events in
            if !events.isDisjoint(with: [.delete, .rename]) { self?.watchFile(queue: queue) }
            self?.reloadFromDisk()
        }
    }

    private func makeSource(
        path: String,
        events: DispatchSource.FileSystemEvent,
        queue: DispatchQueue,
        handler: @escaping (DispatchSource.FileSystemEvent) -> Void
    ) -> DispatchSourceFileSystemObject? {
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return nil }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: events, queue: queue)
        source.setEventHandler { [unowned source] in handler(source.data) }
        source.setCancelHandler { close(fd) }
        source.resume()
        return source
    }

    private func reloadFromDisk() {
        guard let data = try? Data(contentsOf: Self.deckURL) else { return }
        if lock.withLock({ data == lastWrite }) { return }
        guard let deck = try? JSONDecoder().decode(Deck.self, from: data), deck.validationError() == nil else {
            NSLog("macapad: ignoring invalid deck.json edit")
            return
        }
        lock.withLock {
            _deck = deck
            lastWrite = data
        }
        onChange?(deck)
    }
}
