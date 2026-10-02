import StoreKitTest
import XCTest

/// Buys a Trip Pass through StoreKit's test store and checks that the server
/// accepted it: the plans sheet closes and editing unlocks.
///
/// Needs a local server that accepts Xcode test purchases, and a simulator
/// whose newest trip already has a free book:
///
///     PHOTO_ENGINE_TOKEN=sim-test-token PHOTO_ENGINE_PORT=8799 PHOTOCORE_STOREKIT_XCODE=1 photocore-server
final class PurchaseTests: XCTestCase {
    @MainActor
    func testTripPassUnlocksEditing() throws {
        let configuration = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Photocore.storekit")
        let session = try SKTestSession(contentsOf: configuration)
        session.disableDialogs = true
        session.clearTransactions()

        let app = XCUIApplication()
        app.launchArguments = [
            "-PhotocoreAutoOpen", "YES",
            "-PhotocoreServerURL", "http://127.0.0.1:8799",
            "-PhotocoreServerToken", "sim-test-token",
            "-PhotocoreOwnerName", "Ana"
        ]
        app.launch()

        let edit = app.buttons["Edit words"]
        XCTAssertTrue(edit.waitForExistence(timeout: 90), "the finished book's card never appeared")
        for _ in 0..<8 where !edit.isHittable { app.swipeUp(velocity: .slow) }
        edit.tap()

        let sheet = app.navigationBars["Make more books"]
        XCTAssertTrue(sheet.waitForExistence(timeout: 10), "editing a free book didn't offer the plans")
        let buy = app.buttons.matching(NSPredicate(format: "label == '$4.99'")).firstMatch
        XCTAssertTrue(buy.waitForExistence(timeout: 30), "the Trip Pass didn't load from the StoreKit test store")
        let plans = XCTAttachment(screenshot: app.screenshot())
        plans.name = "plans"
        plans.lifetime = .keepAlways
        add(plans)
        buy.tap()

        XCTAssertTrue(sheet.waitForNonExistence(timeout: 60), "the purchase wasn't accepted by the server")
        XCTAssertEqual(session.allTransactions().filter { $0.productIdentifier == "com.photocore.trip.pass.trip" }.count, 1)

        // Editing now opens the book instead of the plans.
        for _ in 0..<4 where !edit.isHittable { app.swipeUp(velocity: .slow) }
        edit.tap()
        XCTAssertFalse(sheet.waitForExistence(timeout: 4), "editing still asks for a plan after the Trip Pass")
    }
}
