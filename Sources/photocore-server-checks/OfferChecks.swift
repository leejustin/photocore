import Foundation
import PhotoEngineWorkflow

extension ServerChecks {
    /// Analysis first: a friend's phone sends offers (feature prints made with
    /// the same engine), the server wants only what the book needs, and only
    /// those originals go up. The finish keeps them without culling again.
    static func exerciseOffers(port: Int, token: String, source: URL) async throws {
        let base = URL(string: "http://127.0.0.1:\(port)")!
        let files = try FileManager.default.contentsOfDirectory(atPath: source.path).filter { $0.hasSuffix(".jpg") }.sorted()
        let trip = try decode(TripWire.self, from: try await postJSON(base.appendingPathComponent("v2/trips"), token: token, body: ["title": "Seoul", "ownerName": "Ana"]).body)
        guard let invite = trip.invitePath else { throw CheckFailure("no invite") }
        for name in files.prefix(2) {
            _ = try await raw(base.appendingPathComponent("v2/trips/\(trip.id)/photos/\((name as NSString).deletingPathExtension)"), method: "PUT", token: token, body: try Data(contentsOf: source.appendingPathComponent(name)))
        }
        let kai = try decode(JoinedWire.self, from: try await send(base.appendingPathComponent(invite + "/join"), method: "POST", json: ["name": "Kai"], headers: [:]).body)
        let status = try decode(InviteStatusWire.self, from: try await data(base.appendingPathComponent(invite + "/status"), headers: ["X-Photocore-Contributor": kai.token]).body)
        try expect(status.ownerName == "Ana", "the invite status doesn't say who's making the book")

        // Kai's phone: one frame like the owner's, one unlike anything, culled
        // with the engine, named the way the App Clip names picks.
        let phone = FileManager.default.temporaryDirectory.appendingPathComponent("kai-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: phone, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: phone) }
        try FileManager.default.copyItem(at: source.appendingPathComponent(files[2]), to: phone.appendingPathComponent("p0001.jpg"))
        try FileManager.default.copyItem(at: source.deletingLastPathComponent().appendingPathComponent("distinct.jpg"), to: phone.appendingPathComponent("p0002.jpg"))
        let offers = try await GroupOffers.offers(source: FilePhotoSource(files: [phone.appendingPathComponent("p0001.jpg"), phone.appendingPathComponent("p0002.jpg")]), storeFolder: phone.appendingPathComponent("store"))
        try expect(offers.count == 2 && offers.allSatisfy({ $0.featurePrint != nil }) && Set(offers.map(\.name)) == ["p0001", "p0002"], "the phone's offers were \(offers.map(\.name))")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let body = try encoder.encode(["offers": offers])
        let stranger = try await raw(base.appendingPathComponent(invite + "/offers"), method: "POST", token: nil, body: body)
        try expect(stranger.status == 401, "offers without a token returned \(stranger.status)")
        let offered = try await raw(base.appendingPathComponent(invite + "/offers"), method: "POST", token: nil, body: body, headers: ["X-Photocore-Contributor": kai.token, "Content-Type": "application/json"])
        try expect(offered.status == 200, "offers returned \(offered.status) \(text(offered.body))")
        let wanted = try decode(WantedWire.self, from: offered.body)
        try expect(wanted.wanted == ["p0002"] && wanted.offered == 2 && wanted.uploaded == 0, "the server wanted \(wanted)")

        // Only the wanted original goes up; then nothing more is wanted.
        let up = try await raw(base.appendingPathComponent(invite + "/photos/p0002"), method: "PUT", token: nil, body: try Data(contentsOf: phone.appendingPathComponent("p0002.jpg")), headers: ["X-Photocore-Contributor": kai.token])
        try expect(up.status == 201, "the wanted upload returned \(up.status)")
        let after = try decode(WantedWire.self, from: try await data(base.appendingPathComponent(invite + "/wanted"), headers: ["X-Photocore-Contributor": kai.token]).body)
        try expect(after.wanted.isEmpty && after.uploaded == 1, "after the upload the server wanted \(after)")

        let finish = try await data(base.appendingPathComponent("v2/trips/\(trip.id)/finish"), method: "POST", token: token)
        let job = try await wait(base: base, token: token, id: try decode(JobWire.self, from: finish.body).id)
        try expect(job.state == "succeeded", "the Seoul finish ended \(job.state) \(job.errorMessage ?? "")")
        let page = text(try await data(base.appendingPathComponent("b/\(trip.slug)/")).body)
        try expect(page.contains("class=\"credit\">Kai<"), "Kai's wanted photo isn't in the book")
        print("✓ offers: the phone culls and offers feature prints, the server wants only what the book needs, one original goes up, the finish keeps it")
    }
}

struct WantedWire: Decodable {
    var wanted: [String]
    var uploaded: Int
    var offered: Int
}
