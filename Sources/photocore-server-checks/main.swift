import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

import PhotoEngineApple
import PhotoEngineServer

@main
struct ServerChecks {
    static func main() async throws {
        setenv("PHOTOCORE_OFFLINE", "1", 1)
        setenv("PHOTOCORE_WRITER", "offline", 1)
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
            try await exerciseTrips(port: port, token: token, source: source)
            group.cancelAll()
        }
        print("All 10 server checks passed")
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

    private static func exerciseTrips(port: Int, token: String, source: URL) async throws {
        let base = URL(string: "http://127.0.0.1:\(port)")!
        let created = try await postJSON(base.appendingPathComponent("v2/trips"), token: token, body: ["title": "Test trip", "tone": "dry"])
        try expect(created.status == 201, "create trip returned \(created.status) \(text(created.body))")
        let trip = try decode(TripWire.self, from: created.body)

        let early = try await data(base.appendingPathComponent("v2/trips/\(trip.id)/finish"), method: "POST", token: token)
        try expect(early.status == 412, "finishing an empty trip returned \(early.status)")

        let files = try FileManager.default.contentsOfDirectory(atPath: source.path).filter { $0.hasSuffix(".jpg") }.sorted()
        for name in files.prefix(4) {
            let bytes = try Data(contentsOf: source.appendingPathComponent(name))
            let up = try await raw(base.appendingPathComponent("v2/trips/\(trip.id)/photos/\((name as NSString).deletingPathExtension)"), method: "PUT", token: token, body: bytes)
            try expect(up.status == 201, "upload returned \(up.status) \(text(up.body))")
        }
        let junk = try await raw(base.appendingPathComponent("v2/trips/\(trip.id)/photos/notaphoto"), method: "PUT", token: token, body: Data("hello".utf8))
        try expect(junk.status == 400, "a non-image upload returned \(junk.status)")
        let noAuthUpload = try await raw(base.appendingPathComponent("v2/trips/\(trip.id)/photos/x"), method: "PUT", token: nil, body: Data([0xFF, 0xD8, 0xFF]))
        try expect(noAuthUpload.status == 401, "an owner upload without the server token returned \(noAuthUpload.status)")

        let finish = try await data(base.appendingPathComponent("v2/trips/\(trip.id)/finish"), method: "POST", token: token)
        try expect(finish.status == 202, "finish returned \(finish.status) \(text(finish.body))")
        let job = try await wait(base: base, token: token, id: try decode(JobWire.self, from: finish.body).id)
        try expect(job.state == "succeeded", "finish job ended \(job.state) \(job.errorMessage ?? "")")

        let page = try await data(base.appendingPathComponent("b/\(trip.slug)/"))
        try expect(page.status == 200 && text(page.body).contains("Test trip"), "public book returned \(page.status)")
        let html = text(page.body)
        guard let photoPath = html.components(separatedBy: "src=\"").dropFirst().first?.components(separatedBy: "\"").first else {
            throw CheckFailure("book page has no photo")
        }
        let photo = try await data(base.appendingPathComponent("b/\(trip.slug)/\(photoPath)"))
        try expect(photo.status == 200 && photo.body.starts(with: [0xFF, 0xD8]), "book photo returned \(photo.status)")
        let caption = try await data(base.appendingPathComponent("b/\(trip.slug)/instagram/caption.txt"))
        try expect(caption.status == 200, "Instagram caption returned \(caption.status)")
        for hidden in ["b/\(trip.slug)/trip.json", "b/\(trip.slug)/book.json", "b/\(trip.slug)/edits.json", "b/\(trip.slug)/..%2Ftrip.json", "b/nosuchbook/"] {
            let probe = try await data(base.appendingPathComponent(hidden))
            try expect(probe.status == 404, "\(hidden) returned \(probe.status)")
        }

        let anonymousEdit = try await send(base.appendingPathComponent("b/\(trip.slug)/edits"), method: "POST", json: ["key": "title", "value": "Hacked"], headers: [:])
        try expect(anonymousEdit.status == 401, "an edit without the owner token returned \(anonymousEdit.status)")
        let serverTokenEdit = try await send(base.appendingPathComponent("b/\(trip.slug)/edits"), method: "POST", token: token, json: ["key": "title", "value": "Hacked"], headers: [:])
        try expect(serverTokenEdit.status == 401, "the server token was accepted as an owner token")
        let badKey = try await send(base.appendingPathComponent("b/\(trip.slug)/edits"), method: "POST", token: trip.ownerToken, json: ["key": "theme", "value": "x"], headers: [:])
        try expect(badKey.status == 400, "editing a protected field returned \(badKey.status)")
        let edit = try await send(base.appendingPathComponent("b/\(trip.slug)/edits"), method: "POST", token: trip.ownerToken, json: ["key": "title", "value": "Our <b>Lisbon</b>"], headers: [:])
        try expect(edit.status == 200, "owner edit returned \(edit.status) \(text(edit.body))")
        let edited = text(try await data(base.appendingPathComponent("b/\(trip.slug)/")).body)
        try expect(edited.contains("Our &lt;b&gt;Lisbon&lt;/b&gt;") && !edited.contains("<b>Lisbon"), "edit was not applied or not escaped")

        let note = try await send(base.appendingPathComponent("b/\(trip.slug)/guest/notes"), method: "POST", json: ["name": "Sam", "text": "Best dinner of the trip"], headers: [:])
        try expect(note.status == 201, "guest note returned \(note.status)")
        let emptyNote = try await send(base.appendingPathComponent("b/\(trip.slug)/guest/notes"), method: "POST", json: ["name": "", "text": ""], headers: [:])
        try expect(emptyNote.status == 400, "an empty note returned \(emptyNote.status)")
        let badHeart = try await send(base.appendingPathComponent("b/\(trip.slug)/guest/hearts"), method: "POST", json: ["photo": "nope"], headers: [:])
        try expect(badHeart.status == 400, "a heart on an unknown photo returned \(badHeart.status)")
        let guestBytes = try Data(contentsOf: source.appendingPathComponent(files.last!))
        let guestUpload = try await raw(base.appendingPathComponent("b/\(trip.slug)/guest/photos/fromsam"), method: "PUT", token: nil, body: guestBytes)
        try expect(guestUpload.status == 201, "guest upload returned \(guestUpload.status) \(text(guestUpload.body))")
        let activity = try await data(base.appendingPathComponent("b/\(trip.slug)/guest"))
        try expect(text(activity.body).contains("Best dinner"), "guest activity is missing the note: \(activity.status) \(text(activity.body).prefix(300))")

        let refinish = try await data(base.appendingPathComponent("v2/trips/\(trip.id)/finish"), method: "POST", token: token)
        let second = try await wait(base: base, token: token, id: try decode(JobWire.self, from: refinish.body).id)
        try expect(second.state == "succeeded", "refinish with a guest photo ended \(second.state) \(second.errorMessage ?? "")")
        let kept = text(try await data(base.appendingPathComponent("b/\(trip.slug)/")).body)
        try expect(kept.contains("Our &lt;b&gt;Lisbon&lt;/b&gt;"), "refinishing lost the owner's edit")

        let preview = try await raw(base.appendingPathComponent("v2/preview"), method: "POST", token: token, body: try Data(contentsOf: source.appendingPathComponent(files[0])))
        try expect(preview.status == 200 && preview.body.starts(with: [0xFF, 0xD8]), "preview returned \(preview.status)")
        print("✓ trips: create, upload, finish, public book, owner edits, guest notes and photos, refinish keeps edits, preview")
    }

    private static func raw(_ url: URL, method: String, token: String?, body: Data) async throws -> HTTPResult {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        let (data, response) = try await Self.session.data(for: request)
        return HTTPResult(status: (response as! HTTPURLResponse).statusCode, body: data, etag: nil)
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

private struct TripWire: Decodable {
    var id: String
    var slug: String
    var ownerToken: String
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
