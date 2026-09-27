import Foundation
import Network
import PhotoEngineCore

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
        createdAt: Date
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
    private var listener: NWListener?
    private var bearerToken: String?
    private var busy = false

    public init() {}

    private func encoded<T: Encodable>(_ value: T) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return (try? encoder.encode(value)) ?? Data()
    }

    public func start(port: UInt16, token: String?) throws {
        let parameters = NWParameters.tcp
        parameters.requiredInterfaceType = .loopback
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw PhotoEngineError.invalidArgument("Port \(port) is invalid.")
        }
        let listener = try NWListener(using: parameters, on: nwPort)
        bearerToken = token?.isEmpty == true ? nil : token
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.stateUpdateHandler = { state in
            if case .failed(let error) = state {
                fputs("photo-engine serve failed: \(error.localizedDescription)\n", stderr)
            }
        }
        listener.start(queue: .global(qos: .userInitiated))
        self.listener = listener
    }

    private func accept(_ connection: NWConnection) {
        let exchange = HTTPExchange(connection: connection)
        exchange.start { [weak self] request in
            guard let self else { return }
            self.route(request, exchange: exchange)
        }
    }

    private func route(_ request: HTTPRequest, exchange: HTTPExchange) {
        if request.method == "OPTIONS" {
            exchange.respond(status: 204, json: Data())
            return
        }
        if let bearerToken {
            let header = request.header("authorization") ?? ""
            guard header == "Bearer \(bearerToken)" else {
                exchange.respond(status: 401, json: jsonObject(["error": "Unauthorized"]))
                return
            }
        }

        let path = request.path
        if request.method == "GET", path == "/v1/health" {
            let health = HealthBody(ok: true, service: "photocore", bind: "loopback", engine: "0.4.0")
            exchange.respond(status: 200, json: encoded(health))
            return
        }
        if request.method == "GET", path == "/v1/jobs" {
            let snapshots = lock.withLock { order.compactMap { jobs[$0] }.reversed() }
            exchange.respond(status: 200, json: encoded(Array(snapshots)))
            return
        }
        if request.method == "POST", path == "/v1/jobs" {
            handleCreate(request, exchange: exchange)
            return
        }
        if request.method == "GET", path.hasPrefix("/v1/jobs/") {
            let remainder = String(path.dropFirst("/v1/jobs/".count))
            let parts = remainder.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
            guard let idString = parts.first, let id = UUID(uuidString: idString) else {
                exchange.respond(status: 404, json: jsonObject(["error": "Job not found"]))
                return
            }
            guard let snapshot = lock.withLock({ jobs[id] }) else {
                exchange.respond(status: 404, json: jsonObject(["error": "Job not found"]))
                return
            }
            if parts.count == 2, parts[1] == "manifest" {
                guard let manifestPath = snapshot.manifestPath,
                      let data = try? Data(contentsOf: URL(fileURLWithPath: manifestPath)) else {
                    exchange.respond(status: 409, json: jsonObject(["error": "Manifest is not ready"]))
                    return
                }
                exchange.respond(status: 200, json: data, contentType: "application/json")
                return
            }
            exchange.respond(status: 200, json: encoded(snapshot))
            return
        }
        exchange.respond(status: 404, json: jsonObject(["error": "Not found"]))
    }

    private func handleCreate(_ request: HTTPRequest, exchange: HTTPExchange) {
        let decoder = JSONDecoder()
        guard !request.body.isEmpty, let jobRequest = try? decoder.decode(CurationJobRequest.self, from: request.body) else {
            exchange.respond(status: 400, json: jsonObject(["error": "Expected a JSON job body"]))
            return
        }
        let source = URL(fileURLWithPath: jobRequest.sourcePath, isDirectory: true).standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: source.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            exchange.respond(status: 400, json: jsonObject(["error": "sourcePath is not a folder on this Mac"]))
            return
        }
        if jobRequest.target != nil && jobRequest.keepPercent != nil {
            exchange.respond(status: 400, json: jsonObject(["error": "Use target or keepPercent, not both"]))
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

        let id = UUID()
        let output = jobRequest.outputPath.map { URL(fileURLWithPath: $0, isDirectory: true).standardizedFileURL }
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("PhotoEngine Exports", isDirectory: true)
                .appendingPathComponent(source.lastPathComponent + "-curated", isDirectory: true)
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
        let requestCopy = jobRequest
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.perform(id: id, request: requestCopy, source: source, output: output)
        }
    }

    private func perform(id: UUID, request: CurationJobRequest, source: URL, output: URL) {
        defer { lock.withLock { busy = false } }
        do {
            var profile = ScoringProfile.default(for: request.profile ?? .everyday)
            profile.apply(aggressiveness: request.cull ?? .balanced)
            profile.style = request.style ?? .natural
            if let intensity = request.intensity {
                guard intensity.isFinite, (0...1).contains(intensity) else {
                    throw PhotoEngineError.invalidArgument("intensity must be between 0 and 1")
                }
                profile.styleIntensity = intensity
            }
            if let keepPercent = request.keepPercent {
                guard (5...90).contains(keepPercent) else {
                    throw PhotoEngineError.invalidArgument("keepPercent must be between 5 and 90")
                }
                profile.sizingMode = .percentage
                profile.keepPercentage = keepPercent
            } else if let target = request.target {
                guard target > 0 else { throw PhotoEngineError.invalidArgument("target must be a positive integer") }
                profile.sizingMode = .count
                profile.targetCount = target
            }
            let runner = PhotoPipelineRunner()
            let result = try runner.run(
                folder: source,
                outputDirectory: output,
                profile: profile,
                exportSpecification: ExportSpecification(preset: request.size ?? .full)
            ) { [weak self] progress in
                self?.update(id) { snapshot in
                    snapshot.message = progress.message
                }
            }
            update(id) { snapshot in
                snapshot.state = "completed"
                snapshot.message = "Selected \(result.shortlist.selectedIDs.count) of \(result.imported.count)"
                snapshot.importedCount = result.imported.count
                snapshot.selectedCount = result.shortlist.selectedIDs.count
                snapshot.manifestPath = result.manifestURL.path
                snapshot.outputPath = result.runDirectory.path
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

    init(connection: NWConnection) {
        self.connection = connection
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
    }

    func respond(status: Int, json: Data, contentType: String = "application/json") {
        let reason: String = switch status {
        case 200: "OK"
        case 202: "Accepted"
        case 204: "No Content"
        case 400: "Bad Request"
        case 401: "Unauthorized"
        case 404: "Not Found"
        case 409: "Conflict"
        case 413: "Payload Too Large"
        default: "Error"
        }
        var header = "HTTP/1.1 \(status) \(reason)\r\n"
        header += "Content-Type: \(contentType)\r\n"
        header += "Content-Length: \(json.count)\r\n"
        header += "Connection: close\r\n"
        header += "Access-Control-Allow-Origin: *\r\n"
        header += "Access-Control-Allow-Headers: Authorization, Content-Type\r\n"
        header += "Access-Control-Allow-Methods: GET, POST, OPTIONS\r\n"
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
