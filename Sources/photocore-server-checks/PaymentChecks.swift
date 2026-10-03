import CryptoKit
import Foundation

extension ServerChecks {
    static let webhookSecret = "whsec_checks_secret"

    /// Web purchases: keeping a book from its page through Stripe (a stand-in
    /// API and signed webhooks), and the no-charge test checkout for a keep
    /// and a printed copy.
    static func exercisePayments(port: Int, devPort: Int, token: String, source: URL, mock: MockLog, outbox: URL) async throws {
        let base = URL(string: "http://127.0.0.1:\(port)")!
        let files = try FileManager.default.contentsOfDirectory(atPath: source.path).filter { $0.hasSuffix(".jpg") }.sorted()
        let trip = try await finishedFreeTrip(base: base, token: token, title: "Kyoto", owner: "Mei", email: "mei@example.com", photo: source.appendingPathComponent(files[1]))
        let page = text(try await data(base.appendingPathComponent("b/\(trip.slug)/")).body)
        try expect(page.contains("id=\"keep\"") && page.contains("Online until") && page.contains("/b/\(trip.slug)/keep"), "a free book has no keep button")
        try expect(!page.contains("photos.zip"), "a free book offers the full-size download")
        let freeZip = try await data(base.appendingPathComponent("b/\(trip.slug)/photos.zip"))
        try expect(freeZip.status == 402, "a free book's download returned \(freeZip.status)")

        // Keep: a Stripe checkout for $4.99 with the trip in its metadata.
        let keep = try await send(base.appendingPathComponent("b/\(trip.slug)/keep"), method: "POST", json: [:], headers: [:])
        try expect(keep.status == 200, "keep returned \(keep.status) \(text(keep.body))")
        let session = try decode(CheckoutWire.self, from: keep.body)
        try expect(session.url.hasPrefix("https://checkout.stripe.test/"), "keep sent the buyer to \(session.url)")
        guard let stripeForm = await mock.bodies("/v1/checkout/sessions").last.map({ String(decoding: $0, as: UTF8.self) }) else { throw CheckFailure("Stripe wasn't called") }
        for part in ["mode=payment", "line_items%5B0%5D%5Bprice_data%5D%5Bunit_amount%5D=499", "metadata%5Bkind%5D=keep", "metadata%5Btrip%5D=\(trip.id)", "thanks%3Fkind%3Dkeep"] {
            try expect(stripeForm.contains(part), "the Stripe checkout is missing \(part): \(stripeForm.prefix(400))")
        }
        try expect(!stripeForm.contains("shipping_address_collection"), "a keep asks for a shipping address")

        // Only signed, fresh events count.
        let event = checkoutEvent(session: session.id, trip: trip.id, kind: "keep", email: "sam@example.com", name: "Sam Rivera")
        let unsigned = try await raw(base.appendingPathComponent("stripe/webhook"), method: "POST", token: nil, body: event)
        try expect(unsigned.status == 400, "an unsigned webhook returned \(unsigned.status)")
        let wrongSecret = try await raw(base.appendingPathComponent("stripe/webhook"), method: "POST", token: nil, body: event, headers: ["Stripe-Signature": sign(event, secret: "whsec_wrong")])
        try expect(wrongSecret.status == 400, "a webhook signed with another secret returned \(wrongSecret.status)")
        let stale = try await raw(base.appendingPathComponent("stripe/webhook"), method: "POST", token: nil, body: event, headers: ["Stripe-Signature": sign(event, secret: webhookSecret, at: Date().addingTimeInterval(-3_600))])
        try expect(stale.status == 400, "an hour-old webhook returned \(stale.status)")
        let other = try JSONSerialization.data(withJSONObject: ["type": "charge.refunded", "data": ["object": ["id": "ch_1"]]])
        let ignored = try await raw(base.appendingPathComponent("stripe/webhook"), method: "POST", token: nil, body: other, headers: ["Stripe-Signature": sign(other, secret: webhookSecret)])
        try expect(ignored.status == 200, "an unrelated event returned \(ignored.status)")

        let before = mails(outbox).count
        let paid = try await raw(base.appendingPathComponent("stripe/webhook"), method: "POST", token: nil, body: event, headers: ["Stripe-Signature": sign(event, secret: webhookSecret)])
        try expect(paid.status == 200, "the paid webhook returned \(paid.status) \(text(paid.body))")
        let status = try decode(PlanStatusWire.self, from: try await data(base.appendingPathComponent("v2/trips/\(trip.id)"), token: token).body)
        try expect(status.plan == "tripPass" && status.hostedUntil == nil, "keeping on the web left the plan \(status.plan)")
        let kept = text(try await data(base.appendingPathComponent("b/\(trip.slug)/")).body)
        try expect(!kept.contains("id=\"keep\"") && kept.contains("/b/\(trip.slug)/photos.zip") && !kept.contains(BookRendererFooter.free), "the kept page wasn't re-rendered")
        let keptMail = mails(outbox).dropFirst(before)
        try expect(keptMail.count == 1 && keptMail.first?.to == "mei@example.com" && keptMail.first?.text.contains("Sam kept") == true, "the kept emails were \(keptMail.map(\.to))")
        let replay = try await raw(base.appendingPathComponent("stripe/webhook"), method: "POST", token: nil, body: event, headers: ["Stripe-Signature": sign(event, secret: webhookSecret)])
        try expect(replay.status == 200 && mails(outbox).count == before + 1, "a repeated webhook applied twice")
        let again = try await send(base.appendingPathComponent("b/\(trip.slug)/keep"), method: "POST", json: [:], headers: [:])
        try expect(again.status == 409, "keeping a kept book returned \(again.status)")

        // A printed copy: Stripe asks for an address and phone; the paid order
        // goes to the printer with files it can fetch, then ships.
        let printSession = try decode(CheckoutWire.self, from: try await send(base.appendingPathComponent("b/\(trip.slug)/print"), method: "POST", json: ["product": "softcover"], headers: [:]).body)
        guard let printForm = await mock.bodies("/v1/checkout/sessions").last.map({ String(decoding: $0, as: UTF8.self) }) else { throw CheckFailure("no print checkout") }
        for part in ["unit_amount%5D=2900", "metadata%5Bkind%5D=print", "metadata%5Bproduct%5D=softcover", "shipping_address_collection%5Ballowed_countries%5D%5B0%5D=US", "phone_number_collection%5Benabled%5D=true"] {
            try expect(printForm.contains(part), "the print checkout is missing \(part)")
        }
        let shipping: [String: Any] = ["name": "Sam Rivera", "address": ["line1": "500 Oak Ave", "line2": "Apt 4", "city": "Austin", "state": "TX", "postal_code": "78701", "country": "US"]]
        let printEvent = checkoutEvent(session: printSession.id, trip: trip.id, kind: "print", email: "sam@example.com", name: "Sam Rivera", shipping: shipping, product: "softcover", cents: 2_900)
        let printPaid = try await raw(base.appendingPathComponent("stripe/webhook"), method: "POST", token: nil, body: printEvent, headers: ["Stripe-Signature": sign(printEvent, secret: webhookSecret)])
        try expect(printPaid.status == 200, "the print webhook returned \(printPaid.status) \(text(printPaid.body))")
        let sentOrders = try decode([OrderWire].self, from: try await data(base.appendingPathComponent("v2/admin/orders"), token: token).body)
        try expect(sentOrders.count == 1 && sentOrders[0].status == "submitted" && sentOrders[0].partnerJobID != nil, "the print order is \(sentOrders)")
        guard let job = await mock.bodies("/print-jobs").last, let jobObject = try JSONSerialization.jsonObject(with: job) as? [String: Any],
              let item = (jobObject["line_items"] as? [[String: Any]])?.first, let printable = item["printable_normalization"] as? [String: Any],
              let interior = (printable["interior"] as? [String: Any])?["source_url"] as? String, let coverURL = (printable["cover"] as? [String: Any])?["source_url"] as? String,
              let address = jobObject["shipping_address"] as? [String: Any]
        else { throw CheckFailure("the print job was malformed") }
        try expect(printable["pod_package_id"] as? String == "0850X0850FCPREPB080CW444GXX" && address["postcode"] as? String == "78701" && address["street2"] as? String == "Apt 4" && address["state_code"] as? String == "TX", "the print job was \(jobObject)")
        try expect(await mock.requests.first { $0.path == "/token" }?.headers["authorization"] == "Basic " + Data("lulu-key:lulu-secret".utf8).base64EncodedString(), "Lulu sign-in used the wrong credentials")
        let dimensions = try JSONSerialization.jsonObject(with: await mock.bodies("/cover-dimensions").last ?? Data()) as? [String: Any]
        let pageCount = dimensions?["interior_page_count"] as? Int ?? 0
        try expect(pageCount >= 32 && pageCount % 2 == 0, "the interior had \(pageCount) pages")
        for link in [interior, coverURL] {
            guard let path = URL(string: link)?.path else { throw CheckFailure("bad file link \(link)") }
            let file = try await data(base.appendingPathComponent(path))
            try expect(file.status == 200 && file.body.starts(with: Array("%PDF".utf8)), "the printer's file \(path) returned \(file.status)")
        }
        let guessed = try await data(base.appendingPathComponent("p/notarealtokennotarealtoken12/interior.pdf"))
        try expect(guessed.status == 404, "a guessed print file returned \(guessed.status)")
        let tick = try await data(base.appendingPathComponent("v2/admin/lifecycle"), method: "POST", token: token)
        try expect(text(tick.body).contains("\"shipped\":1"), "the shipped order wasn't noticed: \(text(tick.body))")
        let shippedMail = mails(outbox).last { $0.kind == "shipped" }
        try expect(shippedMail?.to == "sam@example.com" && shippedMail?.text.contains("https://track.example/") == true, "the shipped email was \(String(describing: shippedMail))")

        // A book that went offline comes back when someone keeps it.
        let lapsed = try await finishedFreeTrip(base: base, token: token, title: "Lapsed", owner: "Jo", email: nil, photo: source.appendingPathComponent(files[0]))
        try await shift(base: base, token: token, trip: lapsed.id, days: 95)
        try expect(try await data(base.appendingPathComponent("b/\(lapsed.slug)/")).status == 410, "the lapsed book is still online")
        let revive = try decode(CheckoutWire.self, from: try await send(base.appendingPathComponent("b/\(lapsed.slug)/keep"), method: "POST", json: [:], headers: [:]).body)
        let revived = checkoutEvent(session: revive.id, trip: lapsed.id, kind: "keep", email: nil, name: nil)
        _ = try await raw(base.appendingPathComponent("stripe/webhook"), method: "POST", token: nil, body: revived, headers: ["Stripe-Signature": sign(revived, secret: webhookSecret)])
        let back = try await data(base.appendingPathComponent("b/\(lapsed.slug)/"))
        try expect(back.status == 200 && text(back.body).contains("photos.zip"), "keeping an offline book didn't bring it back: \(back.status)")

        // The test checkout: a keep and a hardcover, no card.
        let devBase = URL(string: "http://127.0.0.1:\(devPort)")!
        let devTrip = try await finishedFreeTrip(base: devBase, token: token, title: "Oaxaca", owner: "Ana", email: nil, photo: source.appendingPathComponent(files[3]))
        let devKeep = try decode(CheckoutWire.self, from: try await send(devBase.appendingPathComponent("b/\(devTrip.slug)/keep"), method: "POST", json: [:], headers: [:]).body)
        guard let devPath = URL(string: devKeep.url)?.path, devPath.hasPrefix("/checkout/dev/") else { throw CheckFailure("the test checkout link was \(devKeep.url)") }
        let devPage = try await data(devBase.appendingPathComponent(devPath))
        try expect(devPage.status == 200 && text(devPage.body).contains("No card is charged"), "the test checkout page returned \(devPage.status)")
        let paidDev = try await form(devBase.appendingPathComponent(devPath), ["name": "Leo", "email": ""])
        try expect(paidDev.status == 303 && paidDev.location?.contains("/b/\(devTrip.slug)/thanks?kind=keep") == true, "paying the test checkout returned \(paidDev.status) \(paidDev.location ?? "")")
        let reused = try await form(devBase.appendingPathComponent(devPath), ["name": "Leo"])
        try expect(reused.status == 404, "paying a finished test checkout again returned \(reused.status)")
        let devStatus = try decode(PlanStatusWire.self, from: try await data(devBase.appendingPathComponent("v2/trips/\(devTrip.id)"), token: token).body)
        try expect(devStatus.plan == "tripPass", "the test checkout left the plan \(devStatus.plan)")
        let thanks = try await data(devBase.appendingPathComponent("b/\(devTrip.slug)/thanks"), query: "kind=keep")
        try expect(thanks.status == 200 && text(thanks.body).contains("Kept for good"), "the thank-you page returned \(thanks.status)")

        let devPageHTML = text(try await data(devBase.appendingPathComponent("b/\(devTrip.slug)/")).body)
        try expect(devPageHTML.contains("class=\"print-order\"") && devPageHTML.contains("Hardcover book"), "a server that can print shows no print order")
        let badProduct = try await send(devBase.appendingPathComponent("b/\(devTrip.slug)/print"), method: "POST", json: ["product": "poster"], headers: [:])
        try expect(badProduct.status == 400, "an unknown print product returned \(badProduct.status)")
        let printCheckout = try decode(CheckoutWire.self, from: try await send(devBase.appendingPathComponent("b/\(devTrip.slug)/print"), method: "POST", json: ["product": "hardcover"], headers: [:]).body)
        guard let printPath = URL(string: printCheckout.url)?.path else { throw CheckFailure("no print checkout") }
        try expect(text(try await data(devBase.appendingPathComponent(printPath)).body).contains("Postal code"), "the print checkout doesn't ask for an address")
        let printed = try await form(devBase.appendingPathComponent(printPath), ["name": "Leo Park", "email": "leo@example.com", "line1": "1 Main St", "city": "Portland", "state": "OR", "postal": "97201", "country": "us"])
        try expect(printed.status == 303, "paying for a print returned \(printed.status)")
        let orders = try decode([OrderWire].self, from: try await data(devBase.appendingPathComponent("v2/admin/orders"), token: token).body)
        try expect(orders.count == 1 && orders[0].product == "hardcover" && orders[0].shipping.country == "US" && orders[0].shipping.postalCode == "97201" && orders[0].cents == 4_900 && orders[0].status == "submitted", "the print order was \(orders)")
        print("✓ payments: keep from the book page through Stripe, signed and fresh webhooks only, applied once, page re-rendered, kept email, an offline book brought back; a softcover through Stripe to the printer with fetchable files, shipped with tracking; test checkout for a keep and a hardcover")
    }

    static func finishedFreeTrip(base: URL, token: String, title: String, owner: String, email: String?, photo: URL) async throws -> TripWire {
        var body: [String: Any] = ["title": title, "ownerName": owner]
        if let email { body["ownerEmail"] = email }
        let trip = try decode(TripWire.self, from: try await postJSON(base.appendingPathComponent("v2/trips"), token: token, body: body).body)
        let up = try await raw(base.appendingPathComponent("v2/trips/\(trip.id)/photos/one"), method: "PUT", token: token, body: try Data(contentsOf: photo))
        try expect(up.status == 201, "upload returned \(up.status)")
        let finish = try await data(base.appendingPathComponent("v2/trips/\(trip.id)/finish"), method: "POST", token: token)
        let job = try await wait(base: base, token: token, id: try decode(JobWire.self, from: finish.body).id)
        try expect(job.state == "succeeded", "the \(title) finish ended \(job.state) \(job.errorMessage ?? "")")
        return trip
    }

    static func checkoutEvent(session: String, trip: String, kind: String, email: String?, name: String?, shipping: [String: Any]? = nil, product: String? = nil, cents: Int = 499) -> Data {
        var metadata: [String: Any] = ["trip": trip, "kind": kind]
        if let product { metadata["product"] = product }
        var object: [String: Any] = ["id": session, "object": "checkout.session", "payment_status": "paid", "metadata": metadata, "amount_total": cents]
        var customer: [String: Any] = [:]
        if let email { customer["email"] = email }
        if let name { customer["name"] = name }
        object["customer_details"] = customer
        if let shipping { object["collected_information"] = ["shipping_details": shipping] }
        return try! JSONSerialization.data(withJSONObject: ["id": "evt_" + session, "type": "checkout.session.completed", "data": ["object": object]])
    }

    static func sign(_ payload: Data, secret: String, at date: Date = Date()) -> String {
        let timestamp = String(Int(date.timeIntervalSince1970))
        let code = HMAC<SHA256>.authenticationCode(for: Data((timestamp + ".").utf8) + payload, using: SymmetricKey(data: Data(secret.utf8)))
        return "t=\(timestamp),v1=" + code.map { String(format: "%02x", $0) }.joined()
    }

    /// Posts a form like a browser would, without following the redirect.
    static func form(_ url: URL, _ fields: [String: String]) async throws -> (status: Int, location: String?) {
        final class Stop: NSObject, URLSessionTaskDelegate {
            func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest) async -> URLRequest? { nil }
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        request.httpBody = Data(fields.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")" }.joined(separator: "&").utf8)
        let (_, response) = try await Self.session.data(for: request, delegate: Stop())
        let http = response as! HTTPURLResponse
        return (http.statusCode, http.value(forHTTPHeaderField: "Location"))
    }
}

struct CheckoutWire: Decodable {
    var url: String
    var id: String
}

struct OrderWire: Decodable {
    struct Shipping: Decodable { var country: String; var postalCode: String; var name: String }
    var id: String
    var product: String
    var status: String
    var shipping: Shipping
    var cents: Int?
    var partnerJobID: String?
    var error: String?
}
