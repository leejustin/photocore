import Foundation
import Hummingbird
import PhotoEngineServer

@main
struct PhotocoreServerMain {
    static func main() async throws {
        let configuration = ServerConfiguration.fromEnvironment()
        if configuration.tokenWasGenerated {
            print("No PHOTO_ENGINE_TOKEN set. Generated one for this session:")
            print(configuration.security.token)
        }
        let application = try PhotocoreApplication.make(configuration: configuration)
        try await application.runService()
    }
}
