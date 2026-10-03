import Foundation
import Logging
import PhotoEngineWorkflow

/// Where printed books are made.
protocol PrintPartner: Sendable {
    /// The cover sheet for a book of this many interior pages.
    func coverSize(product: PrintProduct, pages: Int) async throws -> BookPrinter.CoverSize
    /// Sends a print job; returns the printer's id for it.
    func submit(order: PrintOrder, title: String, interiorURL: String, coverURL: String) async throws -> String
    /// The job's state, and a tracking link once it ships.
    func status(jobID: String) async throws -> (shipped: Bool, cancelled: Bool, tracking: String?)
    /// Fewest interior pages the printer takes for this product.
    func minimumPages(_ product: PrintProduct) -> Int
}

/// Lulu's Print API. Product ids default to 8.5 x 8.5 inch full-color premium
/// books on 80# coated white paper with a gloss cover; check them against
/// Lulu's pricing calculator before the first real order.
struct LuluPartner: PrintPartner {
    let clientKey: String
    let clientSecret: String
    var apiBase = URL(string: "https://api.lulu.com")!
    var softcoverPackage = "0850X0850FCPREPB080CW444GXX"
    var hardcoverPackage = "0850X0850FCPRECW080CW444GXX"
    var shippingLevel = "MAIL"
    var contactEmail: String

    func package(_ product: PrintProduct) -> String {
        product == .hardcover ? hardcoverPackage : softcoverPackage
    }

    func minimumPages(_ product: PrintProduct) -> Int { product == .hardcover ? 24 : 32 }

    private func token() async throws -> String {
        var request = URLRequest(url: apiBase.appendingPathComponent("auth/realms/glasstree/protocol/openid-connect/token"))
        request.httpMethod = "POST"
        request.setValue("Basic " + Data("\(clientKey):\(clientSecret)".utf8).base64EncodedString(), forHTTPHeaderField: "Authorization")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("grant_type=client_credentials".utf8)
        let object = try await call(request)
        guard let token = object["access_token"] as? String else { throw PrintError.refused("Lulu didn't sign in.") }
        return token
    }

    private func call(_ request: URLRequest) async throws -> [String: Any] {
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status), let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw PrintError.refused("Lulu answered \(status): \(String(decoding: data.prefix(300), as: UTF8.self))")
        }
        return object
    }

    private func authorized(_ path: String, method: String = "POST", json: [String: Any]? = nil) async throws -> [String: Any] {
        var request = URLRequest(url: apiBase.appendingPathComponent(path))
        request.httpMethod = method
        request.setValue("Bearer \(try await token())", forHTTPHeaderField: "Authorization")
        if let json {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: json)
        }
        return try await call(request)
    }

    func coverSize(product: PrintProduct, pages: Int) async throws -> BookPrinter.CoverSize {
        let object = try await authorized("cover-dimensions/", json: ["pod_package_id": package(product), "interior_page_count": pages, "unit": "pt"])
        func number(_ value: Any?) -> Double? { (value as? Double) ?? (value as? Int).map(Double.init) ?? (value as? String).flatMap(Double.init) }
        guard let width = number(object["width"]), let height = number(object["height"]) else { throw PrintError.refused("Lulu didn't give a cover size.") }
        return BookPrinter.CoverSize(width: width, height: height, trim: 612)
    }

    func submit(order: PrintOrder, title: String, interiorURL: String, coverURL: String) async throws -> String {
        var address: [String: Any] = [
            "name": order.shipping.name, "street1": order.shipping.line1, "city": order.shipping.city,
            "postcode": order.shipping.postalCode, "country_code": order.shipping.country,
            // Lulu requires a phone number for the carrier.
            "phone_number": order.phone ?? "0000000000"
        ]
        if let line2 = order.shipping.line2, !line2.isEmpty { address["street2"] = line2 }
        if let state = order.shipping.state, !state.isEmpty { address["state_code"] = state }
        let body: [String: Any] = [
            "contact_email": contactEmail,
            "external_id": order.id,
            "line_items": [[
                "external_id": order.id,
                "title": String(title.prefix(200)),
                "quantity": 1,
                "printable_normalization": [
                    "pod_package_id": package(order.product),
                    "cover": ["source_url": coverURL],
                    "interior": ["source_url": interiorURL]
                ]
            ]],
            "shipping_address": address,
            "shipping_level": shippingLevel
        ]
        let object = try await authorized("print-jobs/", json: body)
        guard let id = (object["id"] as? Int).map(String.init) ?? object["id"] as? String else { throw PrintError.refused("Lulu didn't return a job.") }
        return id
    }

    func status(jobID: String) async throws -> (shipped: Bool, cancelled: Bool, tracking: String?) {
        let object = try await authorized("print-jobs/\(jobID)/", method: "GET")
        let name = (object["status"] as? [String: Any])?["name"] as? String ?? ""
        var tracking: String?
        for item in object["line_items"] as? [[String: Any]] ?? [] {
            let urls = ((item["status"] as? [String: Any])?["messages"] as? [String: Any])?["tracking_urls"] as? [String]
            if let first = urls?.first { tracking = first }
        }
        return (name == "SHIPPED", ["CANCELED", "CANCELLED", "REJECTED"].contains(name), tracking)
    }
}

/// A printer that prints nothing, for development: it makes the files and
/// marks the order sent, so the whole flow can be tried without an account.
struct DevPrintPartner: PrintPartner {
    func coverSize(product: PrintProduct, pages: Int) async throws -> BookPrinter.CoverSize {
        BookPrinter.CoverSize(width: 2 * 621 + 0.0025 * Double(pages) * 72 + 4.5, height: product == .hardcover ? 684 : 630, trim: 612)
    }

    func submit(order: PrintOrder, title: String, interiorURL: String, coverURL: String) async throws -> String { "dev-" + order.id }

    func status(jobID: String) async throws -> (shipped: Bool, cancelled: Bool, tracking: String?) { (false, false, nil) }

    func minimumPages(_ product: PrintProduct) -> Int { product == .hardcover ? 24 : 32 }
}

enum PrintError: Error, CustomStringConvertible {
    case refused(String)
    case noBook

    var description: String {
        switch self {
        case .refused(let text): text
        case .noBook: "The book isn't there to print."
        }
    }
}

/// Turns paid orders into print jobs: makes the interior and cover PDFs,
/// serves them at unguessable links the printer fetches, submits the job and
/// follows it until it ships.
actor PrintFulfillment {
    let partner: any PrintPartner
    let trips: TripStore
    let mailer: any Mailer
    let address: PublicAddress
    private let logger = Logger(label: "Bound.print")
    static let maximumAttempts = 5

    init(partner: any PrintPartner, trips: TripStore, mailer: any Mailer, address: PublicAddress) {
        self.partner = partner
        self.trips = trips
        self.mailer = mailer
        self.address = address
    }

    func filesFolder(_ order: PrintOrder) async -> URL {
        await trips.ordersFolder.appendingPathComponent("files", isDirectory: true).appendingPathComponent(order.id, isDirectory: true)
    }

    /// The printer's link for one of an order's files.
    func fileURL(_ order: PrintOrder, _ name: String) -> String {
        address.base + "/p/" + (order.fileToken ?? "") + "/" + name
    }

    /// Sends every paid order (and failed ones with tries left) to the printer.
    @discardableResult
    func submitPending() async -> Int {
        var sent = 0
        for order in await trips.orders() where order.status == .paid || (order.status == .failed && (order.attempts ?? 0) < Self.maximumAttempts) {
            do {
                try await submit(order)
                sent += 1
            } catch {
                logger.error("Print order failed", metadata: ["order": "\(order.id)", "error": "\(error)"])
                _ = try? await trips.changeOrder(order.id) {
                    $0.status = .failed
                    $0.attempts = ($0.attempts ?? 0) + 1
                    $0.error = "\(error)"
                }
            }
        }
        return sent
    }

    private func submit(_ order: PrintOrder) async throws {
        guard let record = await trips.record(id: order.tripID), record.purgedAt == nil else { throw PrintError.noBook }
        let bookFolder = await trips.bookFolder(record.id)
        let book = BookEdits.load(from: bookFolder).applied(to: try TripBook.load(from: bookFolder))
        let folder = await filesFolder(order)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var current = order
        if current.fileToken == nil {
            current = try await trips.changeOrder(order.id) { $0.fileToken = TripStore.randomToken(length: 32) } ?? current
        }
        let interior = folder.appendingPathComponent("interior.pdf")
        let report = try BookPrinter.pdf(book: book, folder: bookFolder, to: interior, options: .lulu(minimumPages: partner.minimumPages(order.product)))
        let size = try await partner.coverSize(product: order.product, pages: report.pages)
        try BookPrinter.cover(book: book, folder: bookFolder, to: folder.appendingPathComponent("cover.pdf"), size: size)
        let title = record.title.flatMap { $0.isEmpty ? nil : $0 } ?? book.title
        let job = try await partner.submit(order: current, title: title, interiorURL: fileURL(current, "interior.pdf"), coverURL: fileURL(current, "cover.pdf"))
        _ = try await trips.changeOrder(order.id) {
            $0.status = .submitted
            $0.partnerJobID = job
            $0.pages = report.pages
            $0.error = nil
        }
        if let email = order.email {
            try? await mailer.send(MailTemplates.printOrdered(to: email, title: title, product: order.product, orderURL: nil))
        }
    }

    /// Checks sent orders; emails the buyer when one ships.
    @discardableResult
    func followUp() async -> Int {
        var shipped = 0
        for order in await trips.orders() where order.status == .submitted {
            guard let job = order.partnerJobID, let state = try? await partner.status(jobID: job) else { continue }
            if state.shipped {
                _ = try? await trips.changeOrder(order.id) { $0.status = .shipped; $0.trackingURL = state.tracking }
                shipped += 1
                if let email = order.email, let record = await trips.record(id: order.tripID) {
                    let title = record.title.flatMap { $0.isEmpty ? nil : $0 } ?? "your trip"
                    var text = "Your \(order.product.displayName.lowercased()) of \(title) has shipped.\n"
                    if let tracking = state.tracking { text += "\nTrack it: \(tracking)\n" }
                    text += MailTemplates.signature(nil)
                    try? await mailer.send(Mail(to: email, subject: "Your copy of \(title) has shipped", text: text, unsubscribe: nil, kind: "shipped"))
                }
            } else if state.cancelled {
                _ = try? await trips.changeOrder(order.id) { $0.status = .cancelled }
            }
        }
        return shipped
    }

    /// A file the printer asked for, if the token is an order's.
    func file(token: String, name: String) async -> URL? {
        guard ["interior.pdf", "cover.pdf"].contains(name), token.count >= 24 else { return nil }
        for order in await trips.orders() where order.fileToken.map({ TripStore.constantTimeEqual($0, token) }) ?? false {
            let url = await filesFolder(order).appendingPathComponent(name)
            return FileManager.default.fileExists(atPath: url.path) ? url : nil
        }
        return nil
    }
}

enum PrintPartners {
    static func make(_ configuration: ServerConfiguration) -> (any PrintPartner)? {
        if let key = configuration.luluClientKey, !key.isEmpty, let secret = configuration.luluClientSecret, !secret.isEmpty {
            var lulu = LuluPartner(clientKey: key, clientSecret: secret, contactEmail: configuration.printContactEmail ?? configuration.mailFrom ?? "prints@example.com")
            if let base = configuration.luluAPIBase.flatMap(URL.init(string:)) { lulu.apiBase = base }
            if let id = configuration.luluSoftcoverPackage { lulu.softcoverPackage = id }
            if let id = configuration.luluHardcoverPackage { lulu.hardcoverPackage = id }
            if let level = configuration.luluShippingLevel { lulu.shippingLevel = level }
            return lulu
        }
        return configuration.devCheckout ? DevPrintPartner() : nil
    }
}
