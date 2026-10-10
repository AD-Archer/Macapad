import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdWebSocket
import NIOCore

typealias Context = BasicWebSocketRequestContext

struct Health: Codable, ResponseEncodable {
    var ok = true
    var name = "macapad"
    var version = "0.1.0"
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
        let router = Router(context: Context.self)
        router.add(middleware: PrivateNetworkAccessMiddleware())
        router.add(middleware: CORSMiddleware(
            allowOrigin: .originBased,
            allowHeaders: [.accept, .authorization, .contentType, .origin],
            allowMethods: [.get, .post, .options]
        ))
        router.add(middleware: TokenMiddleware(token: token))

        router.get("/api/health") { _, _ in Health() }

        router.post("/api/run") { request, context -> RunResult in
            let body = try await request.decode(as: RunRequest.self, context: context)
            return await Self.execute(body.steps)
        }

        router.ws("/api/ws") { inbound, outbound, _ in
            for try await message in inbound.messages(maxSize: 1 << 20) {
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

/// Requires the API token on /api/* (except health). Accepts `Authorization: Bearer <token>`
/// or `?token=<token>` (browsers can't set headers on WebSocket connections).
struct TokenMiddleware<C: RequestContext>: RouterMiddleware {
    let token: String

    func handle(_ request: Request, context: C, next: (Request, C) async throws -> Response) async throws -> Response {
        let path = request.uri.path
        guard path.hasPrefix("/api/"), path != "/api/health" else {
            return try await next(request, context)
        }
        let bearer = request.headers[.authorization].flatMap { header in
            header.hasPrefix("Bearer ") ? String(header.dropFirst(7)) : nil
        }
        let supplied = bearer ?? request.uri.queryParameters.get("token") ?? ""
        guard constantTimeEquals(supplied, token) else {
            throw HTTPError(.unauthorized, message: "Missing or wrong token")
        }
        return try await next(request, context)
    }

    private func constantTimeEquals(_ a: String, _ b: String) -> Bool {
        let a = Array(a.utf8), b = Array(b.utf8)
        guard a.count == b.count else { return false }
        return zip(a, b).reduce(0) { $0 | ($1.0 ^ $1.1) } == 0
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
