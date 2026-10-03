import Foundation
import PhotoEngineWorkflow

/// One email. Plain text is the source of truth; the HTML part is the same
/// words with links made clickable.
struct Mail: Codable, Sendable, Equatable {
    var to: String
    var subject: String
    var text: String
    /// Where one click stops these emails (RFC 8058).
    var unsubscribe: String?
    /// What kind of email, for the outbox and the logs.
    var kind: String
}

protocol Mailer: Sendable {
    func send(_ mail: Mail) async throws
}

/// Writes each email as JSON under `outbox/`, newest last. The default when no
/// email provider is set up, and what the checks read.
struct OutboxMailer: Mailer {
    let folder: URL

    func send(_ mail: Mail) async throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let name = String(format: "%.6f", Date().timeIntervalSince1970) + "-" + UUID().uuidString.prefix(8) + ".json"
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(mail).write(to: folder.appendingPathComponent(name), options: .atomic)
    }

    func all() -> [Mail] {
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).filter { $0.hasSuffix(".json") }.sorted()
        return names.compactMap { try? JSONDecoder().decode(Mail.self, from: Data(contentsOf: folder.appendingPathComponent($0))) }
    }
}

/// Sends through Resend's HTTP API (`RESEND_API_KEY`, `PHOTOCORE_MAIL_FROM`).
struct ResendMailer: Mailer {
    let apiKey: String
    let from: String
    var endpoint = URL(string: "https://api.resend.com/emails")!

    func send(_ mail: Mail) async throws {
        var body: [String: Any] = [
            "from": from,
            "to": [mail.to],
            "subject": mail.subject,
            "text": mail.text,
            "html": MailTemplates.html(mail.text)
        ]
        if let link = mail.unsubscribe {
            body["headers"] = ["List-Unsubscribe": "<\(link)>", "List-Unsubscribe-Post": "List-Unsubscribe=One-Click"]
        }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw MailError.rejected(status, String(data: data, encoding: .utf8) ?? "")
        }
    }
}

enum MailError: Error, CustomStringConvertible {
    case rejected(Int, String)

    var description: String {
        switch self {
        case .rejected(let status, let body): "The email provider answered \(status): \(body.prefix(200))"
        }
    }
}

enum Mailers {
    static func make(_ configuration: ServerConfiguration, outbox: URL) -> any Mailer {
        if let key = configuration.resendAPIKey, !key.isEmpty, let from = configuration.mailFrom, !from.isEmpty {
            return ResendMailer(apiKey: key, from: from)
        }
        return OutboxMailer(folder: outbox)
    }

    /// A plausible address: something@something.something, no spaces, short.
    static func isAddress(_ text: String) -> Bool {
        guard text.count <= 254, !text.contains(where: { $0.isWhitespace || $0 == "<" || $0 == ">" || $0 == "," }) else { return false }
        let parts = text.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, parts[1].contains("."), !parts[1].hasPrefix("."), !parts[1].hasSuffix(".") else { return false }
        return true
    }
}

/// The emails Bound sends. Short, plain, and only about this one book.
enum MailTemplates {
    static func signature(_ unsubscribe: String?) -> String {
        var lines = ["", "Bound · Finish the trip."]
        if let unsubscribe { lines.append("Stop emails about this book: \(unsubscribe)") }
        return lines.joined(separator: "\n")
    }

    static func reminder(to: String, title: String, credit: String?, until: Date, daysLeft: Int, bookURL: String, unsubscribe: String?) -> Mail {
        let when = daysLeft <= 1 ? "tomorrow" : "in \(daysLeft) days"
        let text = """
        The book of \(title)\(credit.map { ", with \($0.prefix(1).lowercased() + $0.dropFirst())" } ?? "") goes offline \(when), on \(BookRenderer.longDate(until)).

        Free books stay up for 90 days. Anyone in the book can keep it for good for $4.99, with everyone's full-size photos to download:
        \(bookURL)
        \(signature(unsubscribe))
        """
        return Mail(to: to, subject: "\(title) goes offline \(when)", text: text, unsubscribe: unsubscribe, kind: "reminder")
    }

    static func bookReady(to: String, name: String?, title: String, yours: Int, bookURL: String, youURL: String?, unsubscribe: String?) -> Mail {
        var text = "\(name.map { "Hi \($0). " } ?? "")The book of \(title) is ready.\n\n\(bookURL)\n"
        if yours > 0 {
            text += "\n\(yours == 1 ? "One of your photos made it" : "\(yours) of your photos made it") in, with your name under \(yours == 1 ? "it" : "them").\n"
        }
        if let youURL { text += "\nPhotos of you from everyone: \(youURL)\n" }
        text += signature(unsubscribe)
        return Mail(to: to, subject: "The book of \(title) is ready", text: text, unsubscribe: unsubscribe, kind: "ready")
    }

    static func dayIsIn(to: String, title: String, day: Int, newPhotos: Int, bookURL: String, unsubscribe: String?) -> Mail {
        let text = """
        Day \(day) of \(title) is in the book, with \(newPhotos == 1 ? "one new photo" : "\(newPhotos) new photos") from everyone.

        \(bookURL)
        \(signature(unsubscribe))
        """
        return Mail(to: to, subject: "Day \(day) is in", text: text, unsubscribe: unsubscribe, kind: "day")
    }

    static func ownerLink(to: String, title: String, ownerURL: String, inviteURL: String?) -> Mail {
        var text = "Here's your private link to the book of \(title). Keep it to come back, add photos and finish the book:\n\(ownerURL)\n"
        if let inviteURL { text += "\nSend this link to friends so they can add theirs:\n\(inviteURL)\n" }
        text += signature(nil)
        return Mail(to: to, subject: "Your book of \(title)", text: text, unsubscribe: nil, kind: "owner-link")
    }

    static func kept(to: String, title: String, bookURL: String, keptBy: String?) -> Mail {
        let text = """
        \(keptBy.map { "\($0) kept" } ?? "Someone kept") the book of \(title). It stays online for good now, and everyone's full-size photos can be downloaded from it.

        \(bookURL)
        \(signature(nil))
        """
        return Mail(to: to, subject: "\(title) is kept for good", text: text, unsubscribe: nil, kind: "kept")
    }

    static func printOrdered(to: String, title: String, product: PrintProduct, orderURL: String?) -> Mail {
        var text = "Thanks. Your \(product.displayName.lowercased()) of \(title) is being printed. Printing and shipping usually take one to two weeks.\n"
        if let orderURL { text += "\nTrack it here: \(orderURL)\n" }
        text += signature(nil)
        return Mail(to: to, subject: "Your printed copy of \(title)", text: text, unsubscribe: nil, kind: "print")
    }

    /// The same words as HTML, with bare links made clickable.
    static func html(_ text: String) -> String {
        let escaped = text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
        let linked = escaped.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            line.split(separator: " ", omittingEmptySubsequences: false).map { word in
                word.hasPrefix("https://") || word.hasPrefix("http://") ? "<a href=\"\(word)\" style=\"color:#b3322b\">\(word)</a>" : String(word)
            }.joined(separator: " ")
        }.joined(separator: "<br>")
        return "<div style=\"font:16px/1.55 -apple-system,Helvetica,Arial,sans-serif;color:#1e1b18;max-width:560px\">\(linked)</div>"
    }
}
