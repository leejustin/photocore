import Photos
import SwiftUI

/// Receives this iPhone's push token, for "Day 2 is in".
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        PushToken.save(deviceToken)
    }
}

@main
struct PhotocoreApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var queue = TripQueue()

    init() {
        TripQueue.removeLegacyWorkingCopies()
        Store.shared.start()
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
