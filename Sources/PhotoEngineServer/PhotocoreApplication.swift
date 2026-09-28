import Foundation
import Hummingbird
import Logging
import NIOCore
import PhotoEngineApple
import PhotoEnginePersistence

public enum PhotocoreApplication {
    public static func make(configuration: ServerConfiguration, onPort: (@Sendable (Int) -> Void)? = nil) throws -> Application<Router<BasicRequestContext>.Responder> {
        let catalog = try PhotoCatalog(url: configuration.catalogURL)
        _ = try catalog.markInterruptedJobs()
        try FileManager.default.createDirectory(at: configuration.security.outputRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: configuration.mediaCacheDirectory, withIntermediateDirectories: true)
        let runner = PhotoPipelineRunner(catalog: catalog)
        let cancel = CancelFlags()
        let env = ServerEnvironment(
            configuration: configuration,
            catalog: catalog,
            registry: SessionRegistry(catalog: catalog, runner: runner),
            jobs: JobQueue(catalog: catalog, cancel: cancel),
            media: MediaCache(directory: configuration.mediaCacheDirectory),
            runner: runner,
            cancel: cancel
        )
        let router = Router()
        router.middlewares.add(APIMiddleware(security: configuration.security))
        registerJobRoutes(router, env: env)
        registerSessionRoutes(router, env: env)
        registerPhotoRoutes(router, env: env)
        registerMediaRoutes(router, env: env)
        registerLookRoutes(router, env: env)
        return Application(
            router: router,
            configuration: .init(address: .hostname("127.0.0.1", port: configuration.port), serverName: "Photocore"),
            onServerRunning: { channel in
                if let port = channel.localAddress?.port {
                    onPort?(port)
                }
            }
        )
    }
}
