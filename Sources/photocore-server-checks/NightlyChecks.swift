import CryptoKit
import Foundation

extension ServerChecks {
    static let apnsTestKey = P256.Signing.PrivateKey()

    /// During the trip: new photos from a friend are made into the book that
    /// night at 3 a.m. where the trip is, once, and everyone hears about it,
    /// the owner's iPhone included.
    static func exerciseNightly(port: Int, token: String, source: URL, mock: MockLog, outbox: URL) async throws {
        let base = URL(string: "http://127.0.0.1:\(port)")!
        let files = try FileManager.default.contentsOfDirectory(atPath: source.path).filter { $0.hasSuffix(".jpg") }.sorted()
        let trip = try decode(TripWire.self, from: try await postJSON(base.appendingPathComponent("v2/trips"), token: token, body: [
            "title": "Hanoi", "ownerName": "Lan", "ownerEmail": "lan@example.com", "timeZone": "Asia/Ho_Chi_Minh"
        ]).body)
        guard let invite = trip.invitePath else { throw CheckFailure("no invite") }
        _ = try await raw(base.appendingPathComponent("v2/trips/\(trip.id)/photos/one"), method: "PUT", token: token, body: try Data(contentsOf: source.appendingPathComponent(files[0])))
        let zoe = try decode(JoinedWire.self, from: try await send(base.appendingPathComponent(invite + "/join"), method: "POST", json: ["name": "Zoe", "email": "zoe@example.com"], headers: [:]).body)
        let first = try await data(base.appendingPathComponent("v2/trips/\(trip.id)/finish"), method: "POST", token: token)
        _ = try await wait(base: base, token: token, id: try decode(JobWire.self, from: first.body).id)
        let device = String(repeating: "ab12", count: 16)
        let badDevice = try await postJSON(base.appendingPathComponent("v2/trips/\(trip.id)/device"), token: token, body: ["token": "not-hex"])
        try expect(badDevice.status == 400, "a bad device token returned \(badDevice.status)")
        let registered = try await postJSON(base.appendingPathComponent("v2/trips/\(trip.id)/device"), token: token, body: ["token": device])
        try expect(registered.status == 200, "registering the owner's iPhone returned \(registered.status)")

        // 3:15 a.m. in Hanoi with nothing new: no refinish.
        let night = "2026-10-05T20:15:00Z"   // 03:15 on Oct 6 in Hanoi (UTC+7)
        let quiet = try decode(NightlyTick.self, from: try await data(base.appendingPathComponent("v2/admin/lifecycle"), method: "POST", query: "at=\(night)", token: token).body)
        try expect(quiet.other["nightly"] == nil, "a night with no new photos refinished")

        // Zoe adds a photo; the wrong hour does nothing, 3:15 a.m. refinishes once.
        let up = try await raw(base.appendingPathComponent(invite + "/photos/late"), method: "PUT", token: nil, body: try Data(contentsOf: source.deletingLastPathComponent().appendingPathComponent("distinct.jpg")), headers: ["X-Photocore-Contributor": zoe.token])
        try expect(up.status == 201, "Zoe's upload returned \(up.status)")
        let afternoon = try decode(NightlyTick.self, from: try await data(base.appendingPathComponent("v2/admin/lifecycle"), method: "POST", query: "at=2026-10-06T08:00:00Z", token: token).body)
        try expect(afternoon.other["nightly"] == nil, "3 p.m. in Hanoi refinished")
        let mailsBefore = mails(outbox).count
        let refinished = try decode(NightlyTick.self, from: try await data(base.appendingPathComponent("v2/admin/lifecycle"), method: "POST", query: "at=\(night)", token: token).body)
        try expect(refinished.other["nightly"] == 1, "3:15 a.m. with a new photo started \(refinished.other["nightly"] ?? 0) refinishes")
        let status = try decode(NightlyStatus.self, from: try await data(base.appendingPathComponent("v2/trips/\(trip.id)"), token: token).body)
        guard let job = status.lastJobID else { throw CheckFailure("the nightly refinish has no job") }
        let done = try await wait(base: base, token: token, id: job)
        try expect(done.state == "succeeded", "the nightly refinish ended \(done.state) \(done.errorMessage ?? "")")
        let again = try decode(NightlyTick.self, from: try await data(base.appendingPathComponent("v2/admin/lifecycle"), method: "POST", query: "at=2026-10-05T20:40:00Z", token: token).body)
        try expect(again.other["nightly"] == nil, "a second tick the same night refinished again")

        let day = mails(outbox).dropFirst(mailsBefore).filter { $0.kind == "day" }
        try expect(Set(day.map(\.to)) == ["lan@example.com", "zoe@example.com"] && day.allSatisfy({ $0.subject.hasPrefix("Day ") && $0.text.contains("one new photo") }), "the Day emails were \(day.map { "\($0.to): \($0.subject)" })")

        // The owner's iPhone got a push, signed with the team key.
        guard let push = await mock.requests.last(where: { $0.path == "/apns/" + device }) else { throw CheckFailure("no push was sent") }
        try expect(push.headers["apns-topic"] == "com.photocore.trip" && push.headers["apns-push-type"] == "alert", "the push headers were \(push.headers)")
        let alert = ((try JSONSerialization.jsonObject(with: push.body) as? [String: Any])?["aps"] as? [String: Any])?["alert"] as? [String: Any]
        try expect((alert?["title"] as? String)?.hasPrefix("Day ") == true, "the push said \(String(describing: alert))")
        let jwt = (push.headers["authorization"] ?? "").replacingOccurrences(of: "bearer ", with: "").split(separator: ".").map(String.init)
        func decode64(_ text: String) -> Data? {
            var value = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
            while value.count % 4 != 0 { value += "=" }
            return Data(base64Encoded: value)
        }
        guard jwt.count == 3, let header = decode64(jwt[0]), let claims = decode64(jwt[1]), let signature = decode64(jwt[2]),
              let ecdsa = try? P256.Signing.ECDSASignature(rawRepresentation: signature) else { throw CheckFailure("the push token isn't a JWT") }
        let headerObject = try JSONSerialization.jsonObject(with: header) as? [String: Any]
        let claimObject = try JSONSerialization.jsonObject(with: claims) as? [String: Any]
        try expect(headerObject?["kid"] as? String == "KEYCHECK01" && headerObject?["alg"] as? String == "ES256" && claimObject?["iss"] as? String == "TEAMCHECK1", "the push token claims were \(String(describing: headerObject)) \(String(describing: claimObject))")
        try expect(apnsTestKey.publicKey.isValidSignature(ecdsa, for: Data((jwt[0] + "." + jwt[1]).utf8)), "the push token's signature doesn't verify")
        print("✓ nightly: refinish at 3 a.m. where the trip is, only with new photos and once a night; Day emails to everyone; a signed push to the owner's iPhone")
    }
}

struct NightlyTick: Decodable {
    var reminders: Int
    var purged: Int
    var other: [String: Int]
}

struct NightlyStatus: Decodable {
    var lastJobID: String?
    var live: Bool
}
