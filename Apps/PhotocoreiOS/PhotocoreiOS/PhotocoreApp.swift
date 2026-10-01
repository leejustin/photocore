import Photos
import SwiftUI

@main
struct PhotocoreApp: App {
    @State private var queue = TripQueue()

    init() {
        TripQueue.removeLegacyWorkingCopies()
    }

    @AppStorage("PhotocoreWelcomed") private var welcomed = false

    var body: some Scene {
        WindowGroup {
            if welcomed || PHPhotoLibrary.authorizationStatus(for: .readWrite) != .notDetermined {
                HomeView()
                    .environment(queue)
            } else {
                WelcomeView { welcomed = true }
            }
        }
    }
}
