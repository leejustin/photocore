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

    public static func fromEnvironment(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> ServerConfiguration {
        var token = environment["PHOTO_ENGINE_TOKEN"] ?? ""
        var generated = false
        if token.isEmpty {
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
}
