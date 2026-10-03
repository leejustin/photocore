import Foundation

extension ServerChecks {
    /// A book made on the web: started without the app, the owner's photos
    /// culled on the server, finished, and an Event Pass offered.
    static func exerciseWeb(port: Int, token: String, source: URL, mock: MockLog, outbox: URL) async throws {
        let base = URL(string: "http://127.0.0.1:\(port)")!
        let files = try FileManager.default.contentsOfDirectory(atPath: source.path).filter { $0.hasSuffix(".jpg") }.sorted()
        let page = try await data(base.appendingPathComponent("new"))
        try expect(page.status == 200 && text(page.body).contains("Make a book of your trip"), "the new-book page returned \(page.status)")
        let nameless = try await send(base.appendingPathComponent("w/trips"), method: "POST", json: ["title": "Rome"], headers: ["X-Forwarded-For": "203.0.113.9"])
        try expect(nameless.status == 400, "starting a book without a name returned \(nameless.status)")
        let created = try await send(base.appendingPathComponent("w/trips"), method: "POST", json: ["title": "Rome", "ownerName": "Gio", "email": "gio@example.com", "timeZone": "Europe/Rome"], headers: ["X-Forwarded-For": "203.0.113.9"])
        try expect(created.status == 201, "starting a web book returned \(created.status) \(text(created.body))")
        let book = try decode(WebCreatedWire.self, from: created.body)
        try expect(book.ownerPath == "/w/\(book.id)#owner=\(book.ownerToken)", "the owner link was \(book.ownerPath)")
        let link = mails(outbox).last { $0.kind == "owner-link" }
        try expect(link?.to == "gio@example.com" && link?.text.contains(book.ownerPath) == true && link?.text.contains("/j/") == true, "the owner link email was \(String(describing: link))")
        let ownerPage = try await data(base.appendingPathComponent("w/\(book.id)"))
        try expect(ownerPage.status == 200 && text(ownerPage.body).contains("Make the book"), "the owner page returned \(ownerPage.status)")
        let anonymous = try await data(base.appendingPathComponent("w/trips/\(book.id)"))
        try expect(anonymous.status == 401, "the owner status without the token returned \(anonymous.status)")
        let serverToken = try await data(base.appendingPathComponent("w/trips/\(book.id)"), token: token)
        try expect(serverToken.status == 401, "the server token opened a web owner's book")

        // Five photos, four of them near repeats: the server culls the owner's
        // photos and deletes the ones it didn't pick.
        for name in files.prefix(4) + ["distinct.jpg"] {
            let file = name == "distinct.jpg" ? source.deletingLastPathComponent().appendingPathComponent(name) : source.appendingPathComponent(name)
            let up = try await raw(base.appendingPathComponent("w/trips/\(book.id)/photos/\((name as NSString).deletingPathExtension)"), method: "PUT", token: book.ownerToken, body: try Data(contentsOf: file))
            try expect(up.status == 201, "a web owner upload returned \(up.status) \(text(up.body))")
        }
        let finish = try await data(base.appendingPathComponent("w/trips/\(book.id)/finish"), method: "POST", token: book.ownerToken)
        try expect(finish.status == 202, "the web finish returned \(finish.status) \(text(finish.body))")
        var status = try decode(WebStatusWire.self, from: try await data(base.appendingPathComponent("w/trips/\(book.id)"), token: book.ownerToken).body)
        let deadline = Date().addingTimeInterval(90)
        while status.job?.state != "succeeded" && status.job?.state != "failed" && Date() < deadline {
            try await Task.sleep(for: .milliseconds(300))
            status = try decode(WebStatusWire.self, from: try await data(base.appendingPathComponent("w/trips/\(book.id)"), token: book.ownerToken).body)
        }
        try expect(status.job?.state == "succeeded" && status.finishedAt != nil, "the web finish ended \(String(describing: status.job))")
        try expect(status.ownerPhotos < 5 && status.ownerPhotos >= 1, "the server kept \(status.ownerPhotos) of the web owner's 5 photos")
        let bookPage = try await data(base.appendingPathComponent(status.bookPath))
        try expect(bookPage.status == 200 && text(bookPage.body).contains("Rome"), "the web book returned \(bookPage.status)")

        // The Event Pass, on the web.
        let event = try await data(base.appendingPathComponent("w/trips/\(book.id)/event"), method: "POST", token: book.ownerToken)
        try expect(event.status == 200 && text(event.body).contains("checkout.stripe.test"), "the Event Pass checkout returned \(event.status) \(text(event.body))")
        let form = String(decoding: await mock.bodies("/v1/checkout/sessions").last ?? Data(), as: UTF8.self)
        try expect(form.contains("unit_amount%5D=3900") && form.contains("metadata%5Bkind%5D=event") && form.contains("%2Fw%2F\(book.id)"), "the Event Pass checkout was \(form.prefix(300))")

        // Ten new books an hour from one address.
        var refused = 0
        for i in 0..<11 {
            let attempt = try await send(base.appendingPathComponent("w/trips"), method: "POST", json: ["title": "Spam \(i)", "ownerName": "Bot"], headers: ["X-Forwarded-For": "198.51.100.7"])
            if attempt.status == 503 { refused += 1 }
        }
        try expect(refused == 1, "the eleventh book from one address wasn't refused (\(refused) refused)")
        print("✓ web: start a book without the app, owner link by email, owner-only status, the owner's photos culled on the server, finish, Event Pass checkout, ten books an hour per address")
    }
}

struct WebCreatedWire: Decodable {
    var id: String
    var ownerToken: String
    var ownerPath: String
}

struct WebStatusWire: Decodable {
    struct Job: Decodable { var state: String; var message: String?; var error: String? }
    var bookPath: String
    var ownerPhotos: Int
    var finishedAt: Date?
    var job: Job?
}
