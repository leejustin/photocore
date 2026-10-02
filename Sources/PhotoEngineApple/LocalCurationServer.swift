#if os(macOS)
import CryptoKit
import Foundation
import Network
import PhotoEngineCore

public struct WorkerSecurity: Sendable {
    public var token: String
    /// Source folders must live under one of these roots.
    public var allowedRoots: [URL]
    /// Exact `Origin` values allowed for browser clients. Empty = no browser access.
    public var allowedOrigins: Set<String>
    /// Every job writes beneath this folder. Clients cannot choose output paths.
    public var outputRoot: URL

    public init(token: String, allowedRoots: [URL], allowedOrigins: Set<String>, outputRoot: URL) {
        self.token = token
        self.allowedRoots = allowedRoots
        self.allowedOrigins = allowedOrigins
        self.outputRoot = outputRoot
    }

    public static func fromEnvironment(token: String, environment: [String: String] = ProcessInfo.processInfo.environment) -> WorkerSecurity {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let roots = (environment["PHOTO_ENGINE_ALLOWED_ROOTS"] ?? home.appendingPathComponent("Pictures").path)
            .split(separator: ":").map { URL(fileURLWithPath: String($0), isDirectory: true) }
        let origins = Set((environment["PHOTO_ENGINE_ALLOWED_ORIGINS"] ?? "")
            .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
        let outputRoot = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Photocore/worker-runs", isDirectory: true)
        return WorkerSecurity(token: token, allowedRoots: roots, allowedOrigins: origins, outputRoot: outputRoot)
    }

    /// Constant-time bearer check. Length mismatches fail closed without comparing the secret.
    public func acceptsAuthorization(_ header: String?) -> Bool {
        let expected = Array("Bearer \(token)".utf8)
        let provided = Array((header ?? "").utf8)
        guard expected.count == provided.count else { return false }
        var difference: UInt8 = 0
        for (left, right) in zip(expected, provided) { difference |= left ^ right }
        return difference == 0
    }

    /// A readable directory strictly inside an allowed root, or nil.
    public func sourceDirectory(at path: String) -> URL? {
        let url = URL(fileURLWithPath: path, isDirectory: true)
        let canonical = PhotoPipelineRunner.canonicalPath(url)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: canonical, isDirectory: &isDirectory), isDirectory.boolValue else { return nil }
        let prefixes = allowedRoots.map { PhotoPipelineRunner.canonicalPath($0) + "/" }
        guard prefixes.contains(where: { canonical.hasPrefix($0) }) else { return nil }
        return URL(fileURLWithPath: canonical, isDirectory: true)
    }
}

public struct CurationJobRequest: Codable, Sendable, Equatable {
    public var sourcePath: String
    public var outputPath: String?
    public var profile: CurationMode?
    public var cull: CullingAggressiveness?
    public var target: Int?
    public var keepPercent: Double?
    public var style: StylePreset?
    public var intensity: Double?
    public var size: ExportPreset?

    public init(
        sourcePath: String,
        outputPath: String? = nil,
        profile: CurationMode? = nil,
        cull: CullingAggressiveness? = nil,
        target: Int? = nil,
        keepPercent: Double? = nil,
        style: StylePreset? = nil,
        intensity: Double? = nil,
        size: ExportPreset? = nil
    ) {
        self.sourcePath = sourcePath
        self.outputPath = outputPath
        self.profile = profile
        self.cull = cull
        self.target = target
        self.keepPercent = keepPercent
        self.style = style
        self.intensity = intensity
        self.size = size
    }
}

public struct CurationJobSnapshot: Codable, Sendable, Equatable {
    public var id: UUID
    public var state: String
    public var sourcePath: String
    public var outputPath: String?
    public var message: String
    public var importedCount: Int?
    public var selectedCount: Int?
    public var manifestPath: String?
    public var error: String?
    public var createdAt: Date
    public var stage: String?
    public var completed: Int?
    public var total: Int?

    public init(
        id: UUID,
        state: String,
        sourcePath: String,
        outputPath: String? = nil,
        message: String,
        importedCount: Int? = nil,
        selectedCount: Int? = nil,
        manifestPath: String? = nil,
        error: String? = nil,
        createdAt: Date,
        stage: String? = nil,
        completed: Int? = nil,
        total: Int? = nil
    ) {
        self.id = id
        self.state = state
        self.sourcePath = sourcePath
        self.outputPath = outputPath
        self.message = message
        self.importedCount = importedCount
        self.selectedCount = selectedCount
        self.manifestPath = manifestPath
        self.error = error
        self.createdAt = createdAt
        self.stage = stage
        self.completed = completed
        self.total = total
    }
}

/// A loopback HTTP worker around the existing Vision pipeline.
///
/// A phone, folder watcher, or future hosted front end submits a folder that
/// already exists on this Mac. The same binary is what a hosted Apple Silicon
/// worker would run; this process does not upload photographs anywhere.
public final class LocalCurationServer: @unchecked Sendable {
    private let lock = NSLock()
    private var jobs: [UUID: CurationJobSnapshot] = [:]
    private var order: [UUID] = []
    private var cancelledJobs = Set<UUID>()
    private var listener: NWListener?
    private var security: WorkerSecurity?
    private var busy = false

    public init() {}

    private func encoded<T: Encodable>(_ value: T) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return (try? encoder.encode(value)) ?? Data()
    }

    public func start(port: UInt16, security: WorkerSecurity) throws {
        let parameters = NWParameters.tcp
        parameters.requiredInterfaceType = .loopback
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw PhotoEngineError.invalidArgument("Port \(port) is invalid.")
        }
        let listener = try NWListener(using: parameters, on: nwPort)
        self.security = security
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.stateUpdateHandler = { state in
            if case .failed(let error) = state {
                fputs("photo-engine serve failed: \(error.localizedDescription)\n", stderr)
                exit(1)
            }
        }
        listener.start(queue: .global(qos: .userInitiated))
        self.listener = listener
    }

    private func tokenMatches(_ header: String?) -> Bool {
        security?.acceptsAuthorization(header) ?? false
    }

    private func accept(_ connection: NWConnection) {
        let exchange = HTTPExchange(connection: connection)
        exchange.start { [weak self] request in
            guard let self else { return }
            self.route(request, exchange: exchange)
        }
    }

    private func route(_ request: HTTPRequest, exchange: HTTPExchange) {
        let origin = request.header("origin")
        if let origin, security?.allowedOrigins.contains(origin) == true {
            exchange.setCORSOrigin(origin)
        }
        if request.method == "OPTIONS" {
            exchange.respond(status: exchange.hasAllowedOrigin ? 204 : 403, json: Data())
            return
        }
        guard tokenMatches(request.header("authorization")) else {
            exchange.respond(status: 401, json: jsonObject(["error": "Unauthorized"]))
            return
        }

        let path = request.path
        if path == "/v1/health" {
            guard request.method == "GET" else {
                exchange.respond(status: 405, json: jsonObject(["error": "Method not allowed"]))
                return
            }
            let health = HealthBody(ok: true, service: "photocore", bind: "loopback", engine: "0.4.0")
            exchange.respond(status: 200, json: encoded(health))
            return
        }
        if path == "/v1/jobs" {
            if request.method == "GET" {
                let snapshots = lock.withLock { order.compactMap { jobs[$0] }.reversed() }
                exchange.respond(status: 200, json: encoded(Array(snapshots)))
                return
            }
            if request.method == "POST" {
                handleCreate(request, exchange: exchange)
                return
            }
            exchange.respond(status: 405, json: jsonObject(["error": "Method not allowed"]))
            return
        }
        if path.hasPrefix("/v1/jobs/") {
            let remainder = String(path.dropFirst("/v1/jobs/".count))
            let parts = remainder.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
            guard let idString = parts.first, let id = UUID(uuidString: idString) else {
                exchange.respond(status: 404, json: jsonObject(["error": "Job not found"]))
                return
            }
            if parts.count == 2, parts[1] == "cancel" {
                guard request.method == "POST" else {
                    exchange.respond(status: 405, json: jsonObject(["error": "Method not allowed"]))
                    return
                }
                let snapshot = lock.withLock { () -> CurationJobSnapshot? in
                    guard jobs[id] != nil else { return nil }
                    cancelledJobs.insert(id)
                    return jobs[id]
                }
                guard let snapshot else {
                    exchange.respond(status: 404, json: jsonObject(["error": "Job not found"]))
                    return
                }
                exchange.respond(status: 202, json: encoded(snapshot))
                return
            }
            if parts.count == 2, parts[1] == "manifest" {
                guard request.method == "GET" else {
                    exchange.respond(status: 405, json: jsonObject(["error": "Method not allowed"]))
                    return
                }
                guard let snapshot = lock.withLock({ jobs[id] }) else {
                    exchange.respond(status: 404, json: jsonObject(["error": "Job not found"]))
                    return
                }
                guard let manifestPath = snapshot.manifestPath,
                      let data = try? Data(contentsOf: URL(fileURLWithPath: manifestPath)) else {
                    exchange.respond(status: 409, json: jsonObject(["error": "Manifest is not ready"]))
                    return
                }
                exchange.respond(status: 200, json: data, contentType: "application/json")
                return
            }
            if parts.count > 1 {
                exchange.respond(status: 404, json: jsonObject(["error": "Not found"]))
                return
            }
            guard request.method == "GET" else {
                exchange.respond(status: 405, json: jsonObject(["error": "Method not allowed"]))
                return
            }
            guard let snapshot = lock.withLock({ jobs[id] }) else {
                exchange.respond(status: 404, json: jsonObject(["error": "Job not found"]))
                return
            }
            exchange.respond(status: 200, json: encoded(snapshot))
            return
        }
        exchange.respond(status: 404, json: jsonObject(["error": "Not found"]))
    }

    private func handleCreate(_ request: HTTPRequest, exchange: HTTPExchange) {
        let jobRequest: CurationJobRequest
        do {
            jobRequest = try JSONDecoder().decode(CurationJobRequest.self, from: request.body)
        } catch {
            exchange.respond(status: 400, json: jsonObject(["error": "Invalid job body: \(error.localizedDescription)"]))
            return
        }
        if jobRequest.outputPath != nil {
            exchange.respond(status: 400, json: jsonObject(["error": "outputPath is not accepted. Outputs are written under the worker's output root."]))
            return
        }
        guard let security else {
            exchange.respond(status: 403, json: jsonObject(["error": "sourcePath is outside the allowed roots"]))
            return
        }
        let canonicalSourcePath = PhotoPipelineRunner.canonicalPath(URL(fileURLWithPath: jobRequest.sourcePath, isDirectory: true))
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: canonicalSourcePath, isDirectory: &isDirectory)
        let allowedPrefixes = security.allowedRoots.map { PhotoPipelineRunner.canonicalPath($0) + "/" }
        guard exists, isDirectory.boolValue, allowedPrefixes.contains(where: { canonicalSourcePath.hasPrefix($0) }) else {
            exchange.respond(status: 403, json: jsonObject(["error": "sourcePath is outside the allowed roots"]))
            return
        }
        let source = URL(fileURLWithPath: canonicalSourcePath, isDirectory: true)

        let profile: ScoringProfile
        let exportPreset: ExportPreset
        do {
            var built = ScoringProfile.default(for: jobRequest.profile ?? .everyday)
            built.apply(aggressiveness: jobRequest.cull ?? .balanced)
            built.style = jobRequest.style ?? .natural
            if let intensity = jobRequest.intensity {
                guard intensity.isFinite, (0...1).contains(intensity) else {
                    throw PhotoEngineError.invalidArgument("intensity must be between 0 and 1")
                }
                built.styleIntensity = intensity
            }
            if jobRequest.target != nil && jobRequest.keepPercent != nil {
                throw PhotoEngineError.invalidArgument("Use target or keepPercent, not both")
            }
            if let keepPercent = jobRequest.keepPercent {
                guard (5...90).contains(keepPercent) else {
                    throw PhotoEngineError.invalidArgument("keepPercent must be between 5 and 90")
                }
                built.sizingMode = .percentage
                built.keepPercentage = keepPercent
            } else if let target = jobRequest.target {
                guard target > 0 else { throw PhotoEngineError.invalidArgument("target must be a positive integer") }
                built.sizingMode = .count
                built.targetCount = target
            }
            profile = built
            exportPreset = jobRequest.size ?? .full
        } catch {
            exchange.respond(status: 400, json: jsonObject(["error": error.localizedDescription]))
            return
        }

        let accepted = lock.withLock { () -> Bool in
            if busy { return false }
            busy = true
            return true
        }
        guard accepted else {
            exchange.respond(status: 409, json: jsonObject(["error": "A job is already running on this worker"]))
            return
        }

        let output = security.outputRoot.appendingPathComponent(
            safeName(source.lastPathComponent) + "-" + String(sha256(canonicalSourcePath).prefix(10)),
            isDirectory: true
        )
        let id = UUID()
        let snapshot = CurationJobSnapshot(
            id: id,
            state: "running",
            sourcePath: source.path,
            outputPath: output.path,
            message: "Starting",
            createdAt: Date()
        )
        lock.withLock {
            jobs[id] = snapshot
            order.append(id)
            if order.count > 40 {
                let removed = order.removeFirst()
                jobs[removed] = nil
            }
        }
        exchange.respond(status: 202, json: encoded(snapshot))
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.perform(id: id, profile: profile, exportPreset: exportPreset, source: source, output: output)
        }
    }

    private func perform(id: UUID, profile: ScoringProfile, exportPreset: ExportPreset, source: URL, output: URL) {
        defer {
            lock.withLock {
                busy = false
                cancelledJobs.remove(id)
            }
        }
        do {
            let runner = PhotoPipelineRunner()
            let result = try runner.run(
                folder: source,
                outputDirectory: output,
                profile: profile,
                exportSpecification: ExportSpecification(preset: exportPreset),
                progress: { [weak self] progress in
                    self?.update(id) { snapshot in
                        snapshot.message = progress.message
                        snapshot.stage = progress.stage.rawValue
                        snapshot.completed = progress.completed
                        snapshot.total = progress.total
                    }
                },
                shouldCancel: { [weak self] in
                    self?.lock.withLock { self?.cancelledJobs.contains(id) ?? true } ?? true
                }
            )
            update(id) { snapshot in
                snapshot.state = "completed"
                snapshot.message = "Selected \(result.shortlist.selectedIDs.count) of \(result.imported.count)"
                snapshot.importedCount = result.imported.count
                snapshot.selectedCount = result.shortlist.selectedIDs.count
                snapshot.manifestPath = result.manifestURL.path
                snapshot.outputPath = result.runDirectory.path
            }
        } catch is CancellationError {
            update(id) { snapshot in
                snapshot.state = "cancelled"
                snapshot.message = "Cancelled"
            }
        } catch {
            update(id) { snapshot in
                snapshot.state = "failed"
                snapshot.message = "Failed"
                snapshot.error = error.localizedDescription
            }
        }
    }

    private func update(_ id: UUID, _ change: (inout CurationJobSnapshot) -> Void) {
        lock.withLock {
            guard var snapshot = jobs[id] else { return }
            change(&snapshot)
            jobs[id] = snapshot
        }
    }

    private func jsonObject(_ values: [String: String]) -> Data {
        encoded(values)
    }

    private func safeName(_ name: String) -> String {
        let allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789 ._-")
        let cleaned = String(name.map { allowed.contains($0) ? $0 : "-" })
        return cleaned.isEmpty ? "shoot" : cleaned
    }

    private func sha256(_ string: String) -> String {
        SHA256.hash(data: Data(string.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

private struct HealthBody: Codable {
    var ok: Bool
    var service: String
    var bind: String
    var engine: String
}

private struct HTTPRequest {
    var method: String
    var path: String
    var headers: [String: String]
    var body: Data

    func header(_ name: String) -> String? {
        headers[name.lowercased()]
    }
}

private final class HTTPExchange: @unchecked Sendable {
    private let connection: NWConnection
    private var buffer = Data()
    private let maximumBody = 1_048_576
    private var corsOrigin: String?
    private let stateLock = NSLock()
    private var finished = false

    init(connection: NWConnection) {
        self.connection = connection
    }

    func setCORSOrigin(_ origin: String) {
        stateLock.withLock {
            if !finished { corsOrigin = origin }
        }
    }

    var hasAllowedOrigin: Bool {
        stateLock.withLock { corsOrigin != nil }
    }

    func start(handler: @escaping @Sendable (HTTPRequest) -> Void) {
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.read(handler: handler)
            case .failed, .cancelled:
                break
            default:
                break
            }
        }
        connection.start(queue: .global(qos: .userInitiated))
        DispatchQueue.global().asyncAfter(deadline: .now() + 15) { [weak self] in
            self?.respond(status: 408, json: Data("{\"error\":\"Request timeout\"}".utf8))
        }
    }

    func respond(status: Int, json: Data, contentType: String = "application/json") {
        let send = stateLock.withLock { () -> (Bool, String?) in
            if finished { return (false, nil) }
            finished = true
            return (true, corsOrigin)
        }
        guard send.0 else { return }
        let allowedOrigin = send.1
        let reason: String = switch status {
        case 200: "OK"
        case 202: "Accepted"
        case 204: "No Content"
        case 400: "Bad Request"
        case 401: "Unauthorized"
        case 403: "Forbidden"
        case 404: "Not Found"
        case 405: "Method Not Allowed"
        case 408: "Request Timeout"
        case 409: "Conflict"
        case 413: "Payload Too Large"
        case 500: "Internal Server Error"
        default: "Error"
        }
        var header = "HTTP/1.1 \(status) \(reason)\r\n"
        header += "Content-Type: \(contentType)\r\n"
        header += "Content-Length: \(json.count)\r\n"
        header += "Connection: close\r\n"
        if let allowedOrigin {
            header += "Access-Control-Allow-Origin: \(allowedOrigin)\r\n"
            header += "Vary: Origin\r\n"
            header += "Access-Control-Allow-Headers: Authorization, Content-Type\r\n"
            header += "Access-Control-Allow-Methods: GET, POST, OPTIONS\r\n"
        }
        header += "\r\n"
        var payload = Data(header.utf8)
        payload.append(json)
        connection.send(content: payload, completion: .contentProcessed { [connection] _ in
            connection.cancel()
        })
    }

    private func read(handler: @escaping @Sendable (HTTPRequest) -> Void) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data { self.buffer.append(data) }
            if let request = self.parse() {
                handler(request)
                return
            }
            if isComplete || error != nil {
                self.respond(status: 400, json: Data("{\"error\":\"Incomplete request\"}".utf8))
                return
            }
            if self.buffer.count > self.maximumBody + 8_192 {
                self.respond(status: 413, json: Data("{\"error\":\"Request too large\"}".utf8))
                return
            }
            self.read(handler: handler)
        }
    }

    private func parse() -> HTTPRequest? {
        guard let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let headerData = buffer.subdata(in: buffer.startIndex..<headerEnd.lowerBound)
        guard let headerText = String(data: headerData, encoding: .utf8) else { return nil }
        let lines = headerText.split(separator: "\r\n", omittingEmptySubsequences: false).map(String.init)
        guard let requestLine = lines.first else { return nil }
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() where line.contains(":") {
            let pieces = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if pieces.count == 2 { headers[pieces[0].lowercased()] = pieces[1] }
        }
        let contentLength = headers["content-length"].flatMap(Int.init) ?? 0
        guard contentLength >= 0, contentLength <= maximumBody else { return nil }
        let bodyStart = headerEnd.upperBound
        guard buffer.distance(from: bodyStart, to: buffer.endIndex) >= contentLength else { return nil }
        let body = buffer.subdata(in: bodyStart..<buffer.index(bodyStart, offsetBy: contentLength))
        let rawPath = String(parts[1])
        let path = rawPath.split(separator: "?", maxSplits: 1).first.map(String.init) ?? rawPath
        return HTTPRequest(method: String(parts[0]), path: path, headers: headers, body: body)
    }
}
#endif
