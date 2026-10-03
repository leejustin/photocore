import Foundation
import Hummingbird

/// Stand-ins for the outside services the server talks to (Stripe, the
/// printer), recording what they were sent.
actor MockLog {
    private(set) var requests: [(path: String, body: Data, headers: [String: String])] = []
    private var counter = 0

    func record(_ path: String, _ body: Data, _ headers: [String: String]) -> Int {
        requests.append((path, body, headers))
        counter += 1
        return counter
    }

    func bodies(_ path: String) -> [Data] { requests.filter { $0.path == path }.map(\.body) }
    func count(_ path: String) -> Int { requests.filter { $0.path == path }.count }
}

enum MockServices {
    static func make(log: MockLog, onPort: @escaping @Sendable (Int) -> Void) -> some ApplicationProtocol {
        let router = Router()
        router.post("v1/checkout/sessions") { request, _ in
            let body = Data(buffer: try await request.body.collect(upTo: 1_024 * 1_024))
            let n = await log.record("/v1/checkout/sessions", body, ["authorization": request.headers[.authorization] ?? ""])
            return try json(["id": "cs_test_\(n)", "url": "https://checkout.stripe.test/cs_test_\(n)"])
        }
        // The printer: OAuth token, cover size, print jobs.
        router.post("auth/realms/glasstree/protocol/openid-connect/token") { request, _ in
            let body = Data(buffer: try await request.body.collect(upTo: 64 * 1_024))
            _ = await log.record("/token", body, ["authorization": request.headers[.authorization] ?? ""])
            return try json(["access_token": "lulu-test-token", "expires_in": 3600, "token_type": "Bearer"])
        }
        router.post("cover-dimensions") { request, _ in
            let body = Data(buffer: try await request.body.collect(upTo: 64 * 1_024))
            _ = await log.record("/cover-dimensions", body, [:])
            let pages = ((try? JSONSerialization.jsonObject(with: body) as? [String: Any])?["interior_page_count"] as? Int) ?? 32
            let spine = 0.0025 * Double(pages) * 72 + 4.5
            return try json(["width": 2 * 621 + spine, "height": 630, "unit": "pt"])
        }
        router.post("print-jobs") { request, _ in
            let body = Data(buffer: try await request.body.collect(upTo: 1_024 * 1_024))
            let n = await log.record("/print-jobs", body, ["authorization": request.headers[.authorization] ?? ""])
            return try json(["id": 9000 + n, "status": ["name": "CREATED"]])
        }
        router.post("3/device/{token}") { request, context in
            let token = try context.parameters.require("token")
            let body = Data(buffer: try await request.body.collect(upTo: 64 * 1_024))
            _ = await log.record("/apns/" + token, body, [
                "authorization": request.headers[.authorization] ?? "",
                "apns-topic": request.headers.first { $0.name.canonicalName == "apns-topic" }?.value ?? "",
                "apns-push-type": request.headers.first { $0.name.canonicalName == "apns-push-type" }?.value ?? ""
            ])
            return try json([:])
        }
        router.get("print-jobs/{id}") { request, context in
            let id = try context.parameters.require("id")
            _ = await log.record("/print-jobs/status", Data(id.utf8), ["authorization": request.headers[.authorization] ?? ""])
            return try json(["id": Int(id) ?? 0, "status": ["name": "SHIPPED"], "line_items": [["status": ["messages": ["tracking_urls": ["https://track.example/\(id)"]]]]]])
        }
        return Application(
            router: router,
            configuration: .init(address: .hostname("127.0.0.1", port: 0), serverName: "Mock"),
            onServerRunning: { channel in if let port = channel.localAddress?.port { onPort(port) } }
        )
    }

    static func json(_ object: [String: Any]) throws -> Response {
        var headers = HTTPFields()
        headers[.contentType] = "application/json"
        var buffer = ByteBuffer()
        buffer.writeBytes(try JSONSerialization.data(withJSONObject: object))
        return Response(status: .ok, headers: headers, body: .init(byteBuffer: buffer))
    }
}
