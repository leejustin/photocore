import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

import PhotoEngineApple
import PhotoEngineServer

@main
struct ServerChecks {
    static func main() async throws {
        try tokenFileIsPrivate()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("photocore-server-checks-\(UUID().uuidString)", isDirectory: true)
        let source = root.appendingPathComponent("shoot", isDirectory: true)
        let output = root.appendingPathComponent("output", isDirectory: true)
        let cache = root.appendingPathComponent("cache", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for index in 0..<6 {
            try writeJPEG(source.appendingPathComponent("frame-\(index).jpg"), red: CGFloat(index) / 6)
        }
        let token = "server-check-token"
        let configuration = ServerConfiguration(
            port: 0,
            security: WorkerSecurity(token: token, allowedRoots: [root], allowedOrigins: [], outputRoot: output),
            catalogURL: root.appendingPathComponent("catalog.sqlite"),
            mediaCacheDirectory: cache,
            tokenWasGenerated: false
        )
        let portBox = PortBox()
        let application = try PhotocoreApplication.make(configuration: configuration) { portBox.set($0) }
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                do { try await application.runService(gracefulShutdownSignals: []) }
                catch is CancellationError {}
            }
            let port = await portBox.wait()
            try await exercise(port: port, token: token, source: source)
            group.cancelAll()
        }
        print("All 9 server checks passed")
    }

    private static func tokenFileIsPrivate() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("photocore-token-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("server-token")
        let created = try ServerConfiguration.fromEnvironment(["PHOTO_ENGINE_TOKEN_FILE": url.path, "PHOTO_ENGINE_ALLOWED_ROOTS": directory.path])
        try expect(created.tokenWasGenerated == false, "a file token was printed as a generated session token")
        let text = try String(contentsOf: url, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        try expect(text == created.security.token && !text.isEmpty, "token file was not created")
        let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        try expect(mode?.uint16Value == 0o600, "token file mode was \(mode?.uint16Value ?? 0)")
        let again = try ServerConfiguration.fromEnvironment(["PHOTO_ENGINE_TOKEN_FILE": url.path, "PHOTO_ENGINE_ALLOWED_ROOTS": directory.path])
        try expect(again.security.token == text, "existing token file was replaced")
    }

    private static func exercise(port: Int, token: String, source: URL) async throws {
        let base = URL(string: "http://127.0.0.1:\(port)")!
        let health = try await data(base.appendingPathComponent("healthz"))
        try expect(health.status == 200 && String(data: health.body, encoding: .utf8)?.contains("\"ok\":true") == true, "healthz failed \(health.status)")

        let denied = try await data(base.appendingPathComponent("v2/sessions"))
        try expect(denied.status == 401, "missing token returned \(denied.status)")

        let first = try await postJSON(base.appendingPathComponent("v2/sessions"), token: token, body: [
            "sourcePath": source.path, "occasion": "everyday", "cull": "balanced", "target": 4, "renderBase": "raw"
        ])
        try expect(first.status == 202, "create session returned \(first.status) \(text(first.body))")
        let second = try await postJSON(base.appendingPathComponent("v2/sessions"), token: token, body: [
            "sourcePath": source.path, "occasion": "everyday", "target": 2, "renderBase": "raw"
        ])
        let firstJob = try decode(JobWire.self, from: first.body)
        let secondJob = try decode(JobWire.self, from: second.body)
        let cancelled = try await data(base.appendingPathComponent("v2/jobs/\(secondJob.id)/cancel"), method: "POST", token: token)
        try expect(cancelled.status == 202, "cancel returned \(cancelled.status)")
        let cancelledJob = try await wait(base: base, token: token, id: secondJob.id)
        try expect(cancelledJob.state == "cancelled", "cancelled job finished as \(cancelledJob.state)")

        let finished = try await wait(base: base, token: token, id: firstJob.id)
        try expect(finished.state == "succeeded", "curate job finished as \(finished.state) \(finished.errorMessage ?? "")")
        guard let sid = finished.sessionID ?? finished.result?.sessionID else { throw CheckFailure("curate job has no session") }

        let photos = try await data(base.appendingPathComponent("v2/sessions/\(sid)/photos"), query: "set=all", token: token)
        try expect(photos.status == 200, "photos returned \(photos.status)")
        let page = try decode(PhotoPage.self, from: photos.body)
        try expect(!page.items.isEmpty, "session has no photos")
        let photo = page.items[0]

        let wrong = try await send(base.appendingPathComponent("v2/sessions/\(sid)/photos/\(photo.id)"), method: "PATCH", token: token, json: ["stars": 4], headers: ["If-Match": "\"wrong\""])
        try expect(wrong.status == 412, "wrong If-Match returned \(wrong.status)")
        let patched = try await send(base.appendingPathComponent("v2/sessions/\(sid)/photos/\(photo.id)"), method: "PATCH", token: token, json: ["stars": 4], headers: ["If-Match": photo.etag])
        try expect(patched.status == 200, "patch returned \(patched.status) \(text(patched.body))")

        let thumb = try await data(base.appendingPathComponent("v2/media/\(sid)/\(photo.id)/thumb"), token: token)
        try expect(thumb.status == 200, "thumb returned \(thumb.status)")
        guard let etag = thumb.etag else { throw CheckFailure("thumb has no ETag") }
        let cached = try await data(base.appendingPathComponent("v2/media/\(sid)/\(photo.id)/thumb"), token: token, headers: ["If-None-Match": etag])
        try expect(cached.status == 304, "thumb revalidation returned \(cached.status)")

        let delivery = try await postJSON(base.appendingPathComponent("v2/sessions/\(sid)/deliveries"), token: token, body: [
            "exportPreset": "compact", "writeSidecarsBesideOriginals": false
        ])
        try expect(delivery.status == 202, "delivery returned \(delivery.status) \(text(delivery.body))")
        let deliveryJob = try decode(JobWire.self, from: delivery.body)
        let delivered = try await wait(base: base, token: token, id: deliveryJob.id)
        try expect(delivered.state == "succeeded", "delivery finished as \(delivered.state) \(delivered.errorMessage ?? "")")
        print("✓ health, auth, curate, cancel, photos, patch, thumb, delivery")
    }

    private static func wait(base: URL, token: String, id: String) async throws -> JobWire {
        let deadline = Date().addingTimeInterval(90)
        while Date() < deadline {
            let response = try await data(base.appendingPathComponent("v2/jobs/\(id)"), token: token)
            let job = try decode(JobWire.self, from: response.body)
            if ["succeeded", "failed", "cancelled"].contains(job.state) { return job }
            try await Task.sleep(for: .milliseconds(200))
        }
        throw CheckFailure("job \(id) did not finish")
    }

    private static func postJSON(_ url: URL, token: String, body: [String: Any]) async throws -> HTTPResult {
        try await send(url, method: "POST", token: token, json: body, headers: [:])
    }

    private static func data(_ url: URL, method: String = "GET", query: String? = nil, token: String? = nil, headers: [String: String] = [:]) async throws -> HTTPResult {
        try await send(url, method: method, query: query, token: token, json: nil, headers: headers)
    }

    private static func send(_ url: URL, method: String, query: String? = nil, token: String? = nil, json: [String: Any]?, headers: [String: String]) async throws -> HTTPResult {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        if let query { components?.percentEncodedQuery = query }
        var request = URLRequest(url: components?.url ?? url)
        request.httpMethod = method
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        if let json {
            request.httpBody = try JSONSerialization.data(withJSONObject: json)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (body, response) = try await Self.session.data(for: request)
        let http = response as! HTTPURLResponse
        return HTTPResult(status: http.statusCode, body: body, etag: http.value(forHTTPHeaderField: "Etag") ?? http.value(forHTTPHeaderField: "ETag"))
    }

    private static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(type, from: data)
    }

    private static func text(_ data: Data) -> String { String(data: data, encoding: .utf8) ?? "" }

    private static func expect(_ condition: Bool, _ message: String) throws {
        if !condition { throw CheckFailure(message) }
    }

    private static func writeJPEG(_ url: URL, red: CGFloat) throws {
        let width = 128
        let context = CGContext(data: nil, width: width, height: width, bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: red, green: 0.3, blue: 0.5, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: width))
        context.setStrokeColor(CGColor(gray: 1, alpha: 1))
        context.stroke(CGRect(x: 8, y: 8, width: 112, height: 112))
        let image = context.makeImage()!
        let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw CheckFailure("could not write \(url.lastPathComponent)") }
    }
}

private extension ServerChecks {
    static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.urlCache = nil
        return URLSession(configuration: configuration)
    }()
}

private struct HTTPResult {
    var status: Int
    var body: Data
    var etag: String?
}

private struct JobWire: Decodable {
    var id: String
    var state: String
    var sessionID: String?
    var result: ResultBody?
    var error: ErrorBody?
    var errorMessage: String? { error?.message }
    struct ResultBody: Decodable { var sessionID: String? }
    struct ErrorBody: Decodable { var message: String? }
}

private struct PhotoPage: Decodable {
    var items: [PhotoWire]
}

private struct PhotoWire: Decodable {
    var id: String
    var etag: String
}

private struct CheckFailure: Error, CustomStringConvertible {
    var description: String
    init(_ description: String) { self.description = description }
}

private final class PortBox: @unchecked Sendable {
    private let lock = NSLock()
    private var port: Int?
    private var waiters: [CheckedContinuation<Int, Never>] = []

    func set(_ port: Int) {
        lock.lock()
        self.port = port
        let waiters = self.waiters
        self.waiters = []
        lock.unlock()
        waiters.forEach { $0.resume(returning: port) }
    }

    func wait() async -> Int {
        await withCheckedContinuation { continuation in
            lock.lock()
            if let port {
                lock.unlock()
                continuation.resume(returning: port)
            } else {
                waiters.append(continuation)
                lock.unlock()
            }
        }
    }
}
