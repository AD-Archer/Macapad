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

struct PairStatus: Codable, ResponseEncodable {
    /// pending, approved, denied or expired
    var status: String
    var token: String?
    var device: PairedDevice?
}

struct Me: Codable, ResponseEncodable {
    /// True for the token in ~/.macapad/token.
    var owner: Bool
    var device: PairedDevice?
    var mac: MacInfo
}

struct RunRequest: Decodable {
    var steps: [Step]
}

struct RunResult: Codable, ResponseEncodable {
    var ok: Bool
    var error: String?
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
            allowHeaders: [.accept, .authorization, .contentType, .origin],
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
            let name = body.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, name.count <= 60 else {
                throw HTTPError(.badRequest, message: "name is required (up to 60 characters)")
            }
            let app = body.app?.trimmingCharacters(in: .whitespacesAndNewlines).prefix(40)
            do {
                let pair = try Pairing.shared.create(
                    name: name, app: app.flatMap { $0.isEmpty ? nil : String($0) },
                    network: context.network, address: context.remoteAddress ?? ""
                )
                return PairStarted(id: pair.id, code: pair.code, expiresIn: Int(Pairing.lifetime), mac: Self.macInfo(settings))
            } catch let error as PairError {
                throw HTTPError(.tooManyRequests, message: error.localizedDescription)
            }
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
            let mac = Self.macInfo(SettingsStore.shared.current)
            if case .device(let device) = context.caller {
                return Me(owner: false, device: device.publicInfo, mac: mac)
            }
            return Me(owner: true, mac: mac)
        }

        // Lets a device forget this Mac (unpair itself).
        router.delete("/api/me") { _, context -> RunResult in
            guard case .device(let device) = context.caller else {
                throw HTTPError(.badRequest, message: "The owner token can't be unpaired")
            }
            Devices.shared.remove(device.id)
            return RunResult(ok: true)
        }

        router.post("/api/run") { request, context -> RunResult in
            let body = try await request.decode(as: RunRequest.self, context: context)
            return await Self.execute(body.steps)
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

        router.ws("/api/ws") { inbound, outbound, context in
            let suppliedToken = context.request.uri.queryParameters.get("token") ?? ""
            for try await message in inbound.messages(maxSize: 1 << 20) {
                // A device removed in Settings loses its open connection on its next message.
                guard AuthMiddleware.caller(for: suppliedToken, owner: self.token) != nil else {
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
        let wrapped = value.mapValues(AnyEncodable.init)
        return (try? String(decoding: encoder.encode(wrapped), as: UTF8.self)) ?? "{}"
    }
}

private struct AnyEncodable: Encodable {
    let value: any Encodable
    func encode(to encoder: Encoder) throws { try value.encode(to: encoder) }
}

/// Refuses requests from networks turned off in Settings, and records the network on the context.
struct NetworkMiddleware: RouterMiddleware {
    func handle(_ request: Request, context: MacapadContext, next: (Request, MacapadContext) async throws -> Response) async throws -> Response {
        var context = context
        context.network = Network.classify(remote: context.remoteAddress, headers: request.headers)
        guard SettingsStore.shared.current.allows(context.network) else {
            throw HTTPError(.forbidden, message: "Macapad is set to refuse connections from \(context.network.label)")
        }
        return try await next(request, context)
    }
}

/// Requires a token on /api/*, except health and pairing. Accepts the owner token
/// (~/.macapad/token) or a paired device's token, as `Authorization: Bearer <token>`
/// or `?token=<token>` (browsers can't set headers on WebSocket connections).
struct AuthMiddleware: RouterMiddleware {
    let token: String

    func handle(_ request: Request, context: MacapadContext, next: (Request, MacapadContext) async throws -> Response) async throws -> Response {
        let path = request.uri.path
        let isPublic = path == "/api/health"
            || (path == "/api/pair" && request.method == .post)
            || (path.hasPrefix("/api/pair/") && request.method == .get)
        guard path.hasPrefix("/api/"), !isPublic else {
            return try await next(request, context)
        }
        let bearer = request.headers[.authorization].flatMap { header in
            header.hasPrefix("Bearer ") ? String(header.dropFirst(7)) : nil
        }
        let supplied = bearer ?? request.uri.queryParameters.get("token") ?? ""
        guard let caller = Self.caller(for: supplied, owner: token) else {
            throw HTTPError(.unauthorized, message: "Missing or wrong token")
        }
        var context = context
        context.caller = caller
        return try await next(request, context)
    }

    static func caller(for supplied: String, owner: String) -> Caller? {
        guard !supplied.isEmpty else { return nil }
        if Devices.constantTimeEquals(supplied, owner) { return .owner }
        return Devices.shared.authenticate(supplied).map(Caller.device)
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
