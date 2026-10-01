import Foundation
import SafariServices
import SwiftUI

/// Finished books, remembered per trip so the link survives a relaunch.
struct FinishedBook: Codable, Equatable {
    var book: URL
    var edit: URL
    var finishedAt: Date
}

enum BookStore {
    private static let key = "PhotocoreFinishedBooks"

    static func all() -> [String: FinishedBook] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let books = try? JSONDecoder().decode([String: FinishedBook].self, from: data) else { return [:] }
        return books
    }

    static func book(for tripID: String) -> FinishedBook? { all()[tripID] }

    static func save(_ book: FinishedBook, for tripID: String) {
        var books = all()
        books[tripID] = book
        if let data = try? JSONEncoder().encode(books) { UserDefaults.standard.set(data, forKey: key) }
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
