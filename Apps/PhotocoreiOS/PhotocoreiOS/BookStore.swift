import Foundation
import SafariServices
import SwiftUI

/// Finished books, remembered per trip so the link survives a relaunch.
struct FinishedBook: Codable, Equatable {
    var book: URL
    var edit: URL
    var finishedAt: Date
}

/// Finished books per trip. Each edit link carries the owner token, so they
/// live in the Keychain; anything an older build left in UserDefaults moves over once.
enum BookStore {
    private static let key = "PhotocoreFinishedBooks"

    static func all() -> [String: FinishedBook] {
        if let data = Keychain.data(key), let books = try? JSONDecoder().decode([String: FinishedBook].self, from: data) { return books }
        if let legacy = UserDefaults.standard.data(forKey: key), let books = try? JSONDecoder().decode([String: FinishedBook].self, from: legacy) {
            if Keychain.set(legacy, for: key) { UserDefaults.standard.removeObject(forKey: key) }
            return books
        }
        return [:]
    }

    static func book(for tripID: String) -> FinishedBook? { all()[tripID] }

    static func save(_ book: FinishedBook, for tripID: String) {
        var books = all()
        books[tripID] = book
        if let data = try? JSONEncoder().encode(books) { Keychain.set(data, for: key) }
    }
}

/// Opens a book inside the app.
struct SafariView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> SFSafariViewController {
        let controller = SFSafariViewController(url: url)
        controller.preferredControlTintColor = UIColor(named: "AccentColor")
        return controller
    }

    func updateUIViewController(_ controller: SFSafariViewController, context: Context) {}
}

extension URL: @retroactive Identifiable {
    public var id: String { absoluteString }
}
