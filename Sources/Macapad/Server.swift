import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdWebSocket
import NIOCore

/// Per-request context: Hummingbird's WebSocket context plus who's calling and from where.
struct MacapadContext: RequestContext, WebSocketRequestContext {
    typealias Source = ApplicationRequestContextSource
    var coreContext: CoreRequestContextStorage
    let webSocket: WebSocketHandlerReference<Self>
    let remoteAddress: String?
    /// Set by NetworkMiddleware.
    var network: NetworkKind = .internet
    /// The caller's address as shown in Settings (set by NetworkMiddleware).
    var address: String?
    /// Set by AuthMiddleware; nil on the few routes that don't need a token.
    var caller: Caller?

    init(source: ApplicationRequestContextSource) {
        coreContext = .init(source: source)
        webSocket = .init()
        remoteAddress = source.channel.remoteAddress?.ipAddress
    }
}

struct Health: Codable, ResponseEncodable {
    var ok = true
    var name = "macapad"
    /// From Info.plist (set by build-app.sh); "dev" under `swift run`.
    var version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    /// Which network this Mac thinks you're on: thisMac, lan, tailscale or internet.
    var network: NetworkKind?
    /// Only on networks where the Mac is discoverable.
    var mac: MacInfo?
    /// True when you can ask to pair from where you are.
    var pairing: Bool?
}

struct MacInfo: Codable {
    var id: String
    var name: String
}

struct PairStart: Decodable {
    var name: String
    var app: String?
}

struct PairStarted: Codable, ResponseEncodable {
    var id: String
    var code: String
    var expiresIn: Int
    var mac: MacInfo
}

struct QRPairStart: Decodable {
    /// From the QR code's pairing link.
    var key: String
    var name: String
    var app: String?
}

struct PairStatus: Codable, ResponseEncodable {
    /// pending, approved, denied or expired
    var status: String
    var token: String?
    var device: PairedDevice?
    /// Only from QR pairing, which skips the step that tells the device about the Mac.
    var mac: MacInfo?
}

struct Me: Codable, ResponseEncodable {
    /// True for the token in ~/.macapad/token.
    var owner: Bool
    var device: PairedDevice?
    /// The client this request named.
    var client: Client?
    var mac: MacInfo
    /// Set while this token can't run anything (paused, or outside its schedule).
    var off: OffStatus?
}

struct RunRequest: Decodable {
    var steps: [Step]
}

struct RunResult: Codable, ResponseEncodable {
    var ok: Bool
    var error: String?
}

/// The 423 body when the caller is paused or outside its schedule: the usual error, plus why.
struct OffError: Codable, ResponseEncodable {
    struct Message: Codable { var message: String }
    var error: Message
    var off: OffStatus
}

/// Messages a client can send over the WebSocket.
private struct ClientMessage: Decodable {
    var type: String
    var ref: String?
    var steps: [Step]?
}

final class Server: Sendable {
    let token: String
    let port: Int

    init(token: String, port: Int) {
        self.token = token
        self.port = port
    }

    func run() async throws {
        let router = Router(context: MacapadContext.self)
        router.add(middleware: PrivateNetworkAccessMiddleware())
        router.add(middleware: CORSMiddleware(
            allowOrigin: .originBased,
            allowHeaders: [.accept, .authorization, .contentType, .origin, ClientLabel.nameHeader, ClientLabel.keyHeader],
            allowMethods: [.get, .post, .delete, .options]
        ))
        router.add(middleware: NetworkMiddleware())
        router.add(middleware: AuthMiddleware(token: token))

        router.get("/api/health") { _, context -> Health in
            let settings = SettingsStore.shared.current
            guard settings.discoverable(context.network) else { return Health(network: context.network) }
            return Health(network: context.network, mac: Self.macInfo(settings), pairing: true)
        }

        router.post("/api/pair") { request, context -> PairStarted in
            let settings = SettingsStore.shared.current
            guard settings.discoverable(context.network) else {
                throw HTTPError(.forbidden, message: "This Mac doesn't accept pairing requests from \(context.network.label)")
            }
            let body = try await request.decode(as: PairStart.self, context: context)
            let (name, app) = try Self.deviceLabel(name: body.name, app: body.app)
            do {
                let pair = try Pairing.shared.create(
                    name: name, app: app, network: context.network, address: context.remoteAddress ?? ""
                )
                return PairStarted(id: pair.id, code: pair.code, expiresIn: Int(Pairing.lifetime), mac: Self.macInfo(settings))
            } catch let error as PairError {
                throw HTTPError(.tooManyRequests, message: error.localizedDescription)
            }
        }

        // Scanning the QR code the Mac shows pairs right away, with no prompt on the Mac.
        router.post("/api/pair/qr") { request, context -> PairStatus in
            let settings = SettingsStore.shared.current
            guard settings.discoverable(context.network) else {
                throw HTTPError(.forbidden, message: "This Mac doesn't accept pairing requests from \(context.network.label)")
            }
            let body = try await request.decode(as: QRPairStart.self, context: context)
            let (name, app) = try Self.deviceLabel(name: body.name, app: body.app)
            guard let (device, token) = QRPairing.shared.redeem(body.key, name: name, app: app, network: context.network) else {
                throw HTTPError(.gone, message: "This QR code was already used or has expired. Show a new one on the Mac.")
            }
            return PairStatus(status: "approved", token: token, device: device.publicInfo, mac: Self.macInfo(settings))
        }

        // ?wait=<seconds> holds the request open (up to 30s) until you decide on the Mac.
        router.get("/api/pair/:id") { request, context -> PairStatus in
            let id = try context.parameters.require("id")
            let wait = min(30, max(0, request.uri.queryParameters.get("wait").flatMap { Double($0) } ?? 0))
            let deadline = Date().addingTimeInterval(wait)
            while true {
                switch Pairing.shared.collect(id) {
                case .approved(let device, let token):
                    return PairStatus(status: "approved", token: token, device: device.publicInfo)
                case .denied:
                    return PairStatus(status: "denied")
                case nil:
                    return PairStatus(status: "expired")
                case .pending:
                    if Date() >= deadline { return PairStatus(status: "pending") }
                    try await Task.sleep(for: .milliseconds(250))
                }
            }
        }

        router.get("/api/me") { _, context -> Me in
            let settings = SettingsStore.shared.current
            let mac = Self.macInfo(settings)
            let off = Availability.check(context.caller, settings: settings)
            let device = context.caller?.device
            return Me(owner: device == nil, device: device?.publicInfo, client: context.caller?.client, mac: mac, off: off)
        }

        // Lets a device forget this Mac (unpair itself).
        router.delete("/api/me") { _, context -> RunResult in
            guard let device = context.caller?.device else {
                throw HTTPError(.badRequest, message: "The owner token can't be unpaired")
            }
            Devices.shared.remove(device.id)
            Clients.shared.removeAll(deviceId: device.id)
            return RunResult(ok: true)
        }

        router.post("/api/run") { request, context -> Response in
            let body = try await request.decode(as: RunRequest.self, context: context)
            if let off = Availability.check(context.caller, settings: SettingsStore.shared.current) {
                var response = try OffError(error: .init(message: off.message), off: off).response(from: request, context: context)
                response.status = .init(code: 423, reasonPhrase: "Locked")
                return response
            }
            return try await Self.execute(body.steps).response(from: request, context: context)
        }

        router.get("/api/actions") { _, _ in ActionList(actions: Actions.shared.all) }

        router.post("/api/actions") { request, context -> MacAction in
            let action = try await request.decode(as: MacAction.self, context: context)
            do {
                return try Actions.shared.save(action)
            } catch let error as ActionError {
                throw HTTPError(.badRequest, message: error.localizedDescription)
            }
        }

        router.delete("/api/actions/:id") { _, context -> RunResult in
            let id = try context.parameters.require("id")
            guard try Actions.shared.delete(id) else {
                throw HTTPError(.notFound, message: "No custom action with id '\(id)'")
            }
            return RunResult(ok: true)
        }

        router.get("/api/apps") { _, _ in AppList(apps: Apps.list()) }

        router.get("/api/apps/icon") { request, _ -> Response in
            guard let bundleId = request.uri.queryParameters.get("bundleId") else {
                throw HTTPError(.badRequest, message: "bundleId is required")
            }
            let size = min(512, max(16, request.uri.queryParameters.get("size").flatMap { Int($0) } ?? 128))
            guard let png = await Apps.iconPNG(bundleId: bundleId, size: size) else {
                throw HTTPError(.notFound, message: "No app with bundle id '\(bundleId)'")
            }
            return Response(
                status: .ok,
                headers: [.contentType: "image/png", .cacheControl: "max-age=86400"],
                body: .init(byteBuffer: ByteBuffer(bytes: png))
            )
        }

        router.get("/api/shortcuts") { _, _ in ShortcutList(shortcuts: await Apps.shortcuts()) }

        router.get("/api/status") { _, context -> MacStatus in
            let settings = SettingsStore.shared.current
            return await Status.current(mac: Self.macInfo(settings), off: Availability.check(context.caller, settings: settings))
        }

        router.get("/api/status/artwork") { request, _ -> Response in
            let size = min(512, max(16, request.uri.queryParameters.get("size").flatMap { Int($0) } ?? 256))
            guard let png = await NowPlayingReader.shared.artworkPNG(size: size) else {
                throw HTTPError(.notFound, message: "Nothing playing, or the track has no artwork")
            }
            return Response(
                status: .ok,
                headers: [.contentType: "image/png", .cacheControl: "no-store"],
                body: .init(byteBuffer: ByteBuffer(bytes: png))
            )
        }

        router.get("/") { _, _ -> Response in
            guard SettingsStore.shared.current.docsEnabled else {
                throw HTTPError(.notFound, message: "The docs page is off. Turn it on in Macapad's Settings.")
            }
            guard let html = Docs.html() else {
                throw HTTPError(.notFound, message: "This build of Macapad has no docs page")
            }
            return Response(
                status: .ok,
                headers: [.contentType: "text/html; charset=utf-8", .cacheControl: "no-store"],
                body: .init(byteBuffer: ByteBuffer(bytes: html))
            )
        }

        router.ws("/api/ws") { inbound, outbound, context in
            let suppliedToken = context.request.uri.queryParameters.get("token") ?? ""
            // Checked when the connection opened (AuthMiddleware), so this can't fail on a bad name.
            let label = try? ClientLabel.from(context.request)
            for try await message in inbound.messages(maxSize: 1 << 20) {
                // A device removed in Settings loses its open connection on its next message.
                guard let caller = try? AuthMiddleware.caller(
                    for: suppliedToken, owner: self.token, label: label,
                    network: context.requestContext.network, address: context.requestContext.address
                ) else {
                    try await outbound.close(.policyViolation, reason: "Unpaired")
                    return
                }
                guard case .text(let text) = message,
                      let msg = try? JSONDecoder().decode(ClientMessage.self, from: Data(text.utf8))
                else { continue }

                switch msg.type {
                case "ping":
                    try await outbound.write(.text(#"{"type":"pong"}"#))
                case "run":
                    // Run outside the read loop so a long sequence doesn't block the next one.
                    let steps = msg.steps ?? []
                    if let off = Availability.check(caller, settings: SettingsStore.shared.current) {
                        try await outbound.write(.text(Self.encode([
                            "type": "result", "ref": msg.ref ?? "", "ok": false, "error": off.message, "off": off,
                        ])))
                        continue
                    }
                    Task {
                        let result = await Self.execute(steps)
                        try? await outbound.write(.text(Self.encode([
                            "type": "result", "ref": msg.ref ?? "", "ok": result.ok, "error": result.error ?? "",
                        ])))
                    }
                default:
                    continue
                }
            }
        }

        let app = Application(
            router: router,
            server: .http1WebSocketUpgrade(webSocketRouter: router),
            configuration: .init(address: .hostname("0.0.0.0", port: port), serverName: "macapad")
        )
        try await app.runService(gracefulShutdownSignals: [])
    }

    static func macInfo(_ settings: MacapadSettings) -> MacInfo {
        MacInfo(id: settings.id, name: settings.displayName)
    }

    /// The trimmed device name and app a pairing request gives, or a 400.
    static func deviceLabel(name: String, app: String?) throws -> (String, String?) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 60 else {
            throw HTTPError(.badRequest, message: "name is required (up to 60 characters)")
        }
        let app = app.map { String($0.trimmingCharacters(in: .whitespacesAndNewlines).prefix(40)) }
        return (name, app.flatMap { $0.isEmpty ? nil : $0 })
    }

    static func execute(_ steps: [Step]) async -> RunResult {
        do {
            try await Runner.run(steps)
            return RunResult(ok: true)
        } catch {
            return RunResult(ok: false, error: error.localizedDescription)
        }
    }

    static func encode(_ value: [String: any Encodable & Sendable]) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .withoutEscapingSlashes
        encoder.dateEncodingStrategy = .iso8601
        let wrapped = value.mapValues(AnyEncodable.init)
        return (try? String(decoding: encoder.encode(wrapped), as: UTF8.self)) ?? "{}"
    }
}

private struct AnyEncodable: Encodable {
    let value: any Encodable
    func encode(to encoder: Encoder) throws { try value.encode(to: encoder) }
}

/// The docs page (Resources/docs.html), served at / when it's turned on in the menu bar.
enum Docs {
    /// Read on every request, so editing the page under `swift run` shows up on reload.
    static func html() -> Data? {
        let url = Bundle.main.url(forResource: "docs", withExtension: "html")
            ?? URL(fileURLWithPath: #filePath)  // swift run: Sources/Macapad/Server.swift → repo root
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("Resources/docs.html")
        return try? Data(contentsOf: url)
    }
}

/// Refuses requests from networks turned off in Settings, and records the network on the context.
struct NetworkMiddleware: RouterMiddleware {
    func handle(_ request: Request, context: MacapadContext, next: (Request, MacapadContext) async throws -> Response) async throws -> Response {
        var context = context
        context.network = Network.classify(remote: context.remoteAddress, headers: request.headers)
        context.address = Network.address(remote: context.remoteAddress, headers: request.headers)
        guard SettingsStore.shared.current.allows(context.network) else {
            throw HTTPError(.forbidden, message: "Macapad is set to refuse connections from \(context.network.label)")
        }
        return try await next(request, context)
    }
}

/// Requires a token on /api/*, except health and pairing. Accepts the owner token
/// (~/.macapad/token) or a paired device's token, as `Authorization: Bearer <token>`
/// or `?token=<token>` (browsers can't set headers on WebSocket connections).
/// The owner token must also name its client (`X-Macapad-Client` or `?client=`), so each
/// screen or script can have its own schedule; a paired device already has a name.
struct AuthMiddleware: RouterMiddleware {
    let token: String

    static let unnamed = "Name this client: send an X-Macapad-Client header (or ?client= on the WebSocket), "
        + "like “X-Macapad-Client: Office display”. Each name gets its own schedule in Macapad’s Settings."

    func handle(_ request: Request, context: MacapadContext, next: (Request, MacapadContext) async throws -> Response) async throws -> Response {
        let path = request.uri.path
        let isPublic = path == "/api/health"
            || ((path == "/api/pair" || path == "/api/pair/qr") && request.method == .post)
            || (path.hasPrefix("/api/pair/") && request.method == .get)
        guard path.hasPrefix("/api/"), !isPublic else {
            return try await next(request, context)
        }
        let bearer = request.headers[.authorization].flatMap { header in
            header.hasPrefix("Bearer ") ? String(header.dropFirst(7)) : nil
        }
        let supplied = bearer ?? request.uri.queryParameters.get("token") ?? ""
        var context = context
        context.caller = try Self.caller(
            for: supplied, owner: token, label: ClientLabel.from(request), network: context.network, address: context.address
        )
        return try await next(request, context)
    }

    /// The caller for a token and the client it named, or the HTTP error to answer with.
    static func caller(
        for supplied: String, owner: String, label: ClientLabel?, network: NetworkKind, address: String?
    ) throws -> Caller {
        var device: PairedDevice?
        if supplied.isEmpty {
            throw HTTPError(.unauthorized, message: "Missing or wrong token")
        } else if !Devices.constantTimeEquals(supplied, owner) {
            guard let paired = Devices.shared.authenticate(supplied) else {
                throw HTTPError(.unauthorized, message: "Missing or wrong token")
            }
            device = paired
        }
        guard let label else {
            if device == nil { throw HTTPError(.badRequest, message: unnamed) }
            return Caller(device: device)
        }
        do {
            let client = try Clients.shared.resolve(label, deviceId: device?.id, network: network, address: address)
            return Caller(device: device, client: client)
        } catch {
            throw HTTPError(.tooManyRequests, message: error.localizedDescription)
        }
    }
}

/// Lets Chrome pages on public origins call this server on a private address
/// (Chrome's Private Network Access preflight).
struct PrivateNetworkAccessMiddleware<C: RequestContext>: RouterMiddleware {
    func handle(_ request: Request, context: C, next: (Request, C) async throws -> Response) async throws -> Response {
        var response = try await next(request, context)
        if request.headers[HTTPField.Name("Access-Control-Request-Private-Network")!] == "true" {
            response.headers[HTTPField.Name("Access-Control-Allow-Private-Network")!] = "true"
        }
        return response
    }
}
