import Foundation
import HTTPTypes
import Hummingbird

/// A named caller: a screen, script or app that says who it is with `X-Macapad-Client`.
/// Several can share one token (archersdesk calls for every screen it runs), and each gets
/// its own schedule and pause. Saved in ~/.macapad/clients.json.
struct Client: Codable, Sendable, Identifiable, Equatable, ResponseEncodable {
    var id: String
    var name: String
    /// The paired device whose token it calls with. Nil for the owner token.
    var deviceId: String?
    /// What the caller sent as `X-Macapad-Client-Id`, so renaming it keeps its schedule.
    var key: String?
    var firstSeen: Date
    var lastSeen: Date
    /// Where it last called from.
    var network: NetworkKind?
    var address: String?
    /// The schedule (in settings) it works during. Nil = the same as its device
    /// (all the time, for the owner token).
    var scheduleId: String?
    /// The Wi-Fi place (in settings) it works at. Nil = the same as its device
    /// (any network, for the owner token).
    var wifiPlaceId: String?
    /// While set and in the future, it can't run anything. Far future = until turned back on.
    var pausedUntil: Date?
}

/// The name (and optional id) a request gave for its client.
struct ClientLabel: Sendable {
    var name: String
    var key: String?

    static let nameHeader = HTTPField.Name("X-Macapad-Client")!
    static let keyHeader = HTTPField.Name("X-Macapad-Client-Id")!

    /// From the headers, or `?client=` and `?clientId=` (browsers can't set headers on a
    /// WebSocket). Nil when the request didn't name itself; a 400 when the name is unusable.
    static func from(_ request: Request) throws -> ClientLabel? {
        // Header values are ASCII, so names with other characters come percent-encoded.
        let decode = { (raw: String) in raw.removingPercentEncoding ?? raw }
        let query = request.uri.queryParameters
        let rawName = request.headers[nameHeader].map(decode) ?? query.get("client")
        let rawKey = request.headers[keyHeader].map(decode) ?? query.get("clientId")

        guard let rawName else { return nil }
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 60 else {
            throw HTTPError(.badRequest, message: "The client name must be 1 to 60 characters")
        }
        let key = rawKey?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let key, key.count > 64 {
            throw HTTPError(.badRequest, message: "The client id must be up to 64 characters")
        }
        return ClientLabel(name: name, key: key.flatMap { $0.isEmpty ? nil : $0 })
    }
}

enum ClientError: LocalizedError {
    case tooMany

    var errorDescription: String? {
        "This token already has \(Clients.limit) named clients. Forget some in Macapad’s Settings on the Mac."
    }
}

/// Named clients, saved in ~/.macapad/clients.json.
final class Clients: @unchecked Sendable {
    static let shared = Clients()
    /// Per token, so a buggy caller making up names can't fill the Settings window.
    static let limit = 40

    private let lock = NSLock()
    private var clients: [Client]
    private var observers: [@Sendable ([Client]) -> Void] = []
    private var lastWrite = Date.distantPast
    private let fileURL = Config.directory.appendingPathComponent("clients.json")

    private init() {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        clients = (try? decoder.decode([Client].self, from: Data(contentsOf: fileURL))) ?? []
    }

    var all: [Client] { lock.withLock { clients } }

    /// The client a request named, added the first time it calls. A request with an id matches
    /// that id (picking up a new name), or adopts a client of the same name that has none yet;
    /// one without an id matches by name. Names ignore case.
    func resolve(_ label: ClientLabel, deviceId: String?, network: NetworkKind, address: String?) throws -> Client {
        let now = Date()
        let (client, isNew, shouldSave) = try lock.withLock { () -> (Client, Bool, Bool) in
            let mine = clients.indices.filter { clients[$0].deviceId == deviceId }
            let sameName = { (i: Int) in self.clients[i].name.caseInsensitiveCompare(label.name) == .orderedSame }
            let match = label.key.map { key in
                mine.first { self.clients[$0].key == key } ?? mine.first { self.clients[$0].key == nil && sameName($0) }
            } ?? mine.first(where: sameName)

            if let i = match {
                var client = clients[i]
                if label.key != nil {
                    client.name = label.name
                    client.key = label.key
                }
                client.lastSeen = now
                client.network = network
                client.address = address
                let changed = client.name != clients[i].name || client.key != clients[i].key
                    || client.network != clients[i].network || client.address != clients[i].address
                clients[i] = client
                // "Last used" only needs to be roughly right; don't rewrite the file on every press.
                return (client, false, changed || now.timeIntervalSince(lastWrite) > 60)
            }
            guard mine.count < Self.limit else { throw ClientError.tooMany }
            let client = Client(
                id: String(UUID().uuidString.prefix(8)).lowercased(),
                name: label.name, deviceId: deviceId, key: label.key,
                firstSeen: now, lastSeen: now, network: network, address: address
            )
            clients.append(client)
            return (client, true, true)
        }
        if isNew || shouldSave { mutate { _ in } }
        return client
    }

    func remove(_ id: String) {
        mutate { $0.removeAll { $0.id == id } }
    }

    /// A device that's removed takes its clients with it.
    func removeAll(deviceId: String) {
        mutate { $0.removeAll { $0.deviceId == deviceId } }
    }

    func update(_ id: String, _ change: (inout Client) -> Void) {
        mutate { clients in
            guard let i = clients.firstIndex(where: { $0.id == id }) else { return }
            change(&clients[i])
        }
    }

    /// Clients on a schedule or Wi-Fi place that's being deleted go back to following their device.
    func clear(_ field: WritableKeyPath<Client, String?>, matching id: String) {
        mutate { clients in
            for i in clients.indices where clients[i][keyPath: field] == id { clients[i][keyPath: field] = nil }
        }
    }

    func observe(_ observer: @escaping @Sendable ([Client]) -> Void) {
        lock.withLock { observers.append(observer) }
    }

    private func mutate(_ change: (inout [Client]) -> Void) {
        let (next, observers) = lock.withLock { () -> ([Client], [@Sendable ([Client]) -> Void]) in
            change(&clients)
            lastWrite = Date()
            return (clients, self.observers)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(next) {
            try? data.write(to: fileURL, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        }
        observers.forEach { $0(next) }
    }
}
