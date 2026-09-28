import Foundation
import PhotoEngineApple
import PhotoEnginePersistence

public struct ServerConfiguration: Sendable {
    public var port: Int
    public var security: WorkerSecurity
    public var catalogURL: URL
    public var mediaCacheDirectory: URL
    public var tokenWasGenerated: Bool

    public init(port: Int, security: WorkerSecurity, catalogURL: URL, mediaCacheDirectory: URL, tokenWasGenerated: Bool) {
        self.port = port
        self.security = security
        self.catalogURL = catalogURL
        self.mediaCacheDirectory = mediaCacheDirectory
        self.tokenWasGenerated = tokenWasGenerated
    }

    public static func fromEnvironment(_ environment: [String: String] = ProcessInfo.processInfo.environment) throws -> ServerConfiguration {
        var token = environment["PHOTO_ENGINE_TOKEN"] ?? ""
        var generated = false
        if let filePath = environment["PHOTO_ENGINE_TOKEN_FILE"], !filePath.isEmpty {
            token = try tokenFromFile(URL(fileURLWithPath: filePath))
            generated = false
        } else if token.isEmpty {
            token = UUID().uuidString
            generated = true
        }
        let port = Int(environment["PHOTO_ENGINE_PORT"] ?? "") ?? 8787
        let security = WorkerSecurity.fromEnvironment(token: token, environment: environment)
        let cache = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Photocore/media", isDirectory: true)
        return ServerConfiguration(
            port: port,
            security: security,
            catalogURL: PhotoCatalog.defaultURL(),
            mediaCacheDirectory: cache,
            tokenWasGenerated: generated
        )
    }

    /// Reads a token file. Creates a mode-600 file when it is missing.
    private static func tokenFromFile(_ url: URL) throws -> String {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: url.path) {
            let token = try String(contentsOf: url, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !token.isEmpty else {
                throw ServerConfigurationError.emptyTokenFile(url.path)
            }
            return token
        }
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let token = UUID().uuidString
        try Data(token.utf8).write(to: url, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return token
    }
}

enum ServerConfigurationError: Error, CustomStringConvertible {
    case emptyTokenFile(String)

    var description: String {
        switch self {
        case .emptyTokenFile(let path): "PHOTO_ENGINE_TOKEN_FILE is empty: \(path)"
        }
    }
}
