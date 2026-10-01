import SwiftUI

@main
struct PhotocoreApp: App {
    @State private var queue = TripQueue()

    init() {
        TripQueue.removeLegacyWorkingCopies()
    }

    var body: some Scene {
        WindowGroup {
            HomeView()
                .environment(queue)
        }
    }
}
