import Foundation

extension ServerChecks {
    /// Emails and the 90-day life of a free book: the ready email, both
    /// reminders, one-click unsubscribe, the offline page and the purge.
    static func exerciseLifecycle(port: Int, token: String, source: URL, outbox: URL) async throws {
        let base = URL(string: "http://127.0.0.1:\(port)")!
        let files = try FileManager.default.contentsOfDirectory(atPath: source.path).filter { $0.hasSuffix(".jpg") }.sorted()
        let badOwner = try await postJSON(base.appendingPathComponent("v2/trips"), token: token, body: ["title": "Porto", "ownerEmail": "not an email"])
        try expect(badOwner.status == 400, "a bad owner email returned \(badOwner.status)")
        let trip = try decode(TripWire.self, from: try await postJSON(base.appendingPathComponent("v2/trips"), token: token, body: ["title": "Porto", "ownerName": "Ana", "ownerEmail": "ana@example.com"]).body)
        guard let invite = trip.invitePath else { throw CheckFailure("no invite") }
        let badJoin = try await send(base.appendingPathComponent(invite + "/join"), method: "POST", json: ["name": "Sam", "email": "sam@"], headers: [:])
        try expect(badJoin.status == 400, "joining with a bad email returned \(badJoin.status)")
        let sam = try decode(JoinedWire.self, from: try await send(base.appendingPathComponent(invite + "/join"), method: "POST", json: ["name": "Sam", "email": "sam@example.com"], headers: [:]).body)
        let leo = try decode(JoinedWire.self, from: try await send(base.appendingPathComponent(invite + "/join"), method: "POST", json: ["name": "Leo"], headers: [:]).body)
        let leoStatus = try decode(InviteStatusWire.self, from: try await data(base.appendingPathComponent(invite + "/status"), headers: ["X-Photocore-Contributor": leo.token]).body)
        try expect(leoStatus.emailSet == false, "Leo's status says he gave an email")
        let later = try await send(base.appendingPathComponent(invite + "/email"), method: "POST", json: ["email": "leo@example.com"], headers: ["X-Photocore-Contributor": leo.token])
        try expect(later.status == 200, "adding an email later returned \(later.status)")
        let cleared = try await send(base.appendingPathComponent(invite + "/email"), method: "POST", json: ["email": ""], headers: ["X-Photocore-Contributor": leo.token])
        try expect(cleared.status == 200, "clearing an email returned \(cleared.status)")

        let mailBefore = mails(outbox).count
        let up = try await raw(base.appendingPathComponent(invite + "/photos/sam1"), method: "PUT", token: nil, body: try Data(contentsOf: source.appendingPathComponent(files[2])), headers: ["X-Photocore-Contributor": sam.token])
        try expect(up.status == 201, "Sam's upload returned \(up.status)")
        let finish = try await data(base.appendingPathComponent("v2/trips/\(trip.id)/finish"), method: "POST", token: token)
        let job = try await wait(base: base, token: token, id: try decode(JobWire.self, from: finish.body).id)
        try expect(job.state == "succeeded", "the Porto finish ended \(job.state) \(job.errorMessage ?? "")")
        let ready = mails(outbox).dropFirst(mailBefore)
        try expect(ready.count == 1 && ready.first?.to == "sam@example.com" && ready.first?.kind == "ready" && ready.first?.text.contains("One of your photos made it") == true,
                   "the ready emails were \(ready.map { "\($0.to) \($0.kind)" })")
        let refinish = try await data(base.appendingPathComponent("v2/trips/\(trip.id)/finish"), method: "POST", token: token)
        _ = try await wait(base: base, token: token, id: try decode(JobWire.self, from: refinish.body).id)
        try expect(mails(outbox).count == mailBefore + 1, "a refinish sent the ready email again")

        // Photos of you: only for someone who joined; these test frames have no faces.
        let you = try await data(base.appendingPathComponent(invite + "/you"), headers: ["X-Photocore-Contributor": sam.token])
        try expect(you.status == 200 && text(you.body).contains("\"available\":false"), "photos of you returned \(you.status) \(text(you.body))")
        let strangerYou = try await data(base.appendingPathComponent(invite + "/you"))
        try expect(strangerYou.status == 401, "photos of you without a token returned \(strangerYou.status)")
        let badFace = try await data(base.appendingPathComponent(invite + "/faces/../../trip.json"))
        try expect(badFace.status == 404, "a face path outside the crops returned \(badFace.status)")
        let noFaceZip = try await data(base.appendingPathComponent(invite + "/you.zip"), headers: ["X-Photocore-Contributor": sam.token])
        try expect(noFaceZip.status == 404, "a zip with no photos of you returned \(noFaceZip.status)")

        // Six days left: the first reminder, to Ana and Sam, once.
        try await shift(base: base, token: token, trip: trip.id, days: 84)
        let first = try decode(TickWire.self, from: try await data(base.appendingPathComponent("v2/admin/lifecycle"), method: "POST", token: token).body)
        try expect(first.reminders == 2, "the first reminder went to \(first.reminders) people")
        let reminder = mails(outbox).last { $0.kind == "reminder" && $0.to == "sam@example.com" }
        try expect(reminder?.subject == "Porto goes offline in 6 days" && reminder?.text.contains("/b/\(trip.slug)/") == true, "the reminder was \(String(describing: reminder))")
        let again = try decode(TickWire.self, from: try await data(base.appendingPathComponent("v2/admin/lifecycle"), method: "POST", token: token).body)
        try expect(again.reminders == 0, "a second tick sent \(again.reminders) more reminders")

        // Sam stops emails from the link in his reminder.
        guard let link = reminder?.unsubscribe, let path = URL(string: link)?.path else { throw CheckFailure("the reminder has no unsubscribe link") }
        let page = try await data(base.appendingPathComponent(path))
        try expect(page.status == 200 && text(page.body).contains("Stop emails"), "the unsubscribe page returned \(page.status)")
        let stop = try await data(base.appendingPathComponent(path), method: "POST")
        try expect(stop.status == 200 && text(stop.body).contains("No more emails"), "unsubscribing returned \(stop.status)")
        let forged = try await data(base.appendingPathComponent("u/\(trip.id).notarealtoken"), method: "POST")
        try expect(forged.status == 404, "a forged unsubscribe returned \(forged.status)")

        // Half a day left: the last reminder, to Ana only now.
        try await shift(base: base, token: token, trip: trip.id, days: 5.5)
        let last = try decode(TickWire.self, from: try await data(base.appendingPathComponent("v2/admin/lifecycle"), method: "POST", token: token).body)
        try expect(last.reminders == 1 && mails(outbox).last?.subject == "Porto goes offline tomorrow" && mails(outbox).last?.to == "ana@example.com", "the last reminder was \(last.reminders) \(String(describing: mails(outbox).last))")

        // Offline: the page offers to keep it; photos are gone.
        try await shift(base: base, token: token, trip: trip.id, days: 1)
        let offline = try await data(base.appendingPathComponent("b/\(trip.slug)/"))
        try expect(offline.status == 410 && text(offline.body).contains("Porto is offline") && text(offline.body).contains("Keep it for $4.99"), "the offline book returned \(offline.status)")
        let offlinePhoto = try await data(base.appendingPathComponent("b/\(trip.slug)/photos/x.jpg"))
        try expect(offlinePhoto.status == 410, "an offline photo returned \(offlinePhoto.status)")

        // A month later nobody kept it: the photos are deleted.
        try await shift(base: base, token: token, trip: trip.id, days: 31)
        let purge = try decode(TickWire.self, from: try await data(base.appendingPathComponent("v2/admin/lifecycle"), method: "POST", token: token).body)
        try expect(purge.purged == 1, "the purge removed \(purge.purged) books")
        let purged = try await data(base.appendingPathComponent("b/\(trip.slug)/"))
        try expect(purged.status == 410 && text(purged.body).contains("photos have been deleted") && !text(purged.body).contains("Keep it"), "the purged book returned \(purged.status)")
        let closed = try await send(base.appendingPathComponent(invite + "/join"), method: "POST", json: ["name": "Late"], headers: [:])
        try expect(closed.status == 403, "joining a purged book returned \(closed.status)")
        print("✓ lifecycle: photos of you only for people who joined, emails at join and later, ready email once, reminders at a week and a day, one-click unsubscribe, offline page, purge after 30 days")
    }

    static func shift(base: URL, token: String, trip: String, days: Double) async throws {
        let shifted = try await postJSON(base.appendingPathComponent("v2/admin/trips/\(trip)/shift"), token: token, body: ["days": days])
        try expect(shifted.status == 200, "shifting the trip returned \(shifted.status)")
    }

    static func mails(_ outbox: URL) -> [MailWire] {
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: outbox.path)) ?? []).filter { $0.hasSuffix(".json") }.sorted()
        return names.compactMap { try? JSONDecoder().decode(MailWire.self, from: Data(contentsOf: outbox.appendingPathComponent($0))) }
    }
}

struct MailWire: Decodable {
    var to: String
    var subject: String
    var text: String
    var unsubscribe: String?
    var kind: String
}

struct TickWire: Decodable {
    var reminders: Int
    var purged: Int
}
