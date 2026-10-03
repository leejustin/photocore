import CryptoKit
import Foundation
import PhotoEngineWorkflow

/// What a web checkout buys.
enum CheckoutKind: String, Codable, Sendable {
    /// A Trip Pass bought from the book page by anyone in the book.
    case keep
    /// An Event Pass bought by someone who made their book on the web.
    case event
    /// A printed copy, shipped.
    case print
}

struct ShippingAddress: Codable, Sendable, Equatable {
    var name: String
    var line1: String
    var line2: String?
    var city: String
    var state: String?
    var postalCode: String
    var country: String
}

/// A checkout to start: one item, one price, back to the book afterwards.
struct CheckoutRequest: Sendable {
    var kind: CheckoutKind
    var tripID: String
    var slug: String
    var title: String
    var cents: Int
    var product: PrintProduct?
    var successURL: String
    var cancelURL: String
    var collectShipping: Bool { kind == .print }

    var itemName: String {
        switch kind {
        case .keep: "Trip Pass · \(title)"
        case .event: "Event Pass · \(title)"
        case .print: "\(product?.displayName ?? "Printed book") · \(title)"
        }
    }

    var itemDescription: String {
        switch kind {
        case .keep: "Keeps the book online for good, with everyone's full-size photos to download."
        case .event: "Up to 100 friends with 300 photos each, kept for good."
        case .print: "An 8.5 inch square printed book. Standard shipping included."
        }
    }
}

/// A paid checkout, from Stripe's webhook or the test checkout.
struct CheckoutCompletion: Sendable, Equatable {
    var sessionID: String
    var kind: CheckoutKind
    var tripID: String
    var product: PrintProduct?
    var email: String?
    var name: String?
    var shipping: ShippingAddress?
    var cents: Int?
}

protocol PaymentProvider: Sendable {
    /// Starts a checkout and returns its id and the page to send the buyer to.
    func createCheckout(_ request: CheckoutRequest) async throws -> (id: String, url: String)
}

/// Countries printed books ship to, with standard shipping in the price.
enum ShippingCountries {
    static let allowed = ["US", "CA", "GB", "IE", "AU", "NZ", "DE", "FR", "NL", "BE", "ES", "IT", "PT", "AT", "DK", "SE", "FI", "NO", "CH"]
}

/// Stripe Checkout with prices set inline, so nothing has to be created in the
/// Stripe dashboard first.
struct StripePayments: PaymentProvider {
    let secretKey: String
    var apiBase = URL(string: "https://api.stripe.com")!

    func createCheckout(_ request: CheckoutRequest) async throws -> (id: String, url: String) {
        var form: [(String, String)] = [
            ("mode", "payment"),
            ("success_url", request.successURL),
            ("cancel_url", request.cancelURL),
            ("client_reference_id", request.tripID),
            ("line_items[0][quantity]", "1"),
            ("line_items[0][price_data][currency]", "usd"),
            ("line_items[0][price_data][unit_amount]", String(request.cents)),
            ("line_items[0][price_data][product_data][name]", request.itemName),
            ("line_items[0][price_data][product_data][description]", request.itemDescription),
            ("metadata[trip]", request.tripID),
            ("metadata[kind]", request.kind.rawValue),
            ("payment_intent_data[metadata][trip]", request.tripID),
            ("payment_intent_data[metadata][kind]", request.kind.rawValue)
        ]
        if let product = request.product { form.append(("metadata[product]", product.rawValue)) }
        if request.collectShipping {
            for (index, country) in ShippingCountries.allowed.enumerated() {
                form.append(("shipping_address_collection[allowed_countries][\(index)]", country))
            }
        }
        var http = URLRequest(url: apiBase.appendingPathComponent("v1/checkout/sessions"))
        http.httpMethod = "POST"
        http.setValue("Bearer \(secretKey)", forHTTPHeaderField: "Authorization")
        http.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        http.httpBody = Data(Self.encode(form).utf8)
        let (data, response) = try await URLSession.shared.data(for: http)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        struct Session: Decodable { var id: String; var url: String? }
        guard (200..<300).contains(status), let session = try? JSONDecoder().decode(Session.self, from: data), let url = session.url else {
            throw APIError.busy("Checkout isn't available right now. Try again in a moment.")
        }
        return (session.id, url)
    }

    static func encode(_ form: [(String, String)]) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return form.map { key, value in
            (key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key) + "=" + (value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value)
        }.joined(separator: "&")
    }
}

/// Reads Stripe's signed webhook events.
enum StripeWebhook {
    /// Checks the `Stripe-Signature` header: an HMAC-SHA256 of
    /// "<timestamp>.<raw body>" with the endpoint secret, within five minutes.
    static func verify(payload: Data, header: String?, secret: String, now: Date = Date(), tolerance: TimeInterval = 300) -> Bool {
        guard let header else { return false }
        var timestamp: String?
        var signatures: [String] = []
        for part in header.split(separator: ",") {
            let pair = part.split(separator: "=", maxSplits: 1).map(String.init)
            guard pair.count == 2 else { continue }
            if pair[0] == "t" { timestamp = pair[1] }
            if pair[0] == "v1" { signatures.append(pair[1]) }
        }
        guard let timestamp, let seconds = TimeInterval(timestamp), abs(now.timeIntervalSince1970 - seconds) <= tolerance else { return false }
        let signed = Data((timestamp + ".").utf8) + payload
        let expected = HMAC<SHA256>.authenticationCode(for: signed, using: SymmetricKey(data: Data(secret.utf8)))
            .map { String(format: "%02x", $0) }.joined()
        return signatures.contains { TripStore.constantTimeEqual($0, expected) }
    }

    /// The signature header for a payload; used by the test checkout and the checks.
    static func sign(payload: Data, secret: String, at date: Date = Date()) -> String {
        let timestamp = String(Int(date.timeIntervalSince1970))
        let code = HMAC<SHA256>.authenticationCode(for: Data((timestamp + ".").utf8) + payload, using: SymmetricKey(data: Data(secret.utf8)))
        return "t=\(timestamp),v1=" + code.map { String(format: "%02x", $0) }.joined()
    }

    /// A paid checkout from a `checkout.session.completed` event, or nil for
    /// any other event or an unpaid session.
    static func completion(from payload: Data) -> CheckoutCompletion? {
        guard let event = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
              event["type"] as? String == "checkout.session.completed" || event["type"] as? String == "checkout.session.async_payment_succeeded",
              let object = (event["data"] as? [String: Any])?["object"] as? [String: Any],
              let id = object["id"] as? String,
              object["payment_status"] as? String == "paid",
              let metadata = object["metadata"] as? [String: Any],
              let trip = metadata["trip"] as? String,
              let kind = (metadata["kind"] as? String).flatMap(CheckoutKind.init(rawValue:))
        else { return nil }
        let customer = object["customer_details"] as? [String: Any]
        // Newer API versions put shipping under collected_information.
        let shippingObject = ((object["collected_information"] as? [String: Any])?["shipping_details"] as? [String: Any])
            ?? object["shipping_details"] as? [String: Any]
        var shipping: ShippingAddress?
        if let details = shippingObject, let address = details["address"] as? [String: Any],
           let line1 = address["line1"] as? String, let city = address["city"] as? String,
           let postal = address["postal_code"] as? String, let country = address["country"] as? String {
            shipping = ShippingAddress(
                name: details["name"] as? String ?? customer?["name"] as? String ?? "",
                line1: line1, line2: address["line2"] as? String, city: city,
                state: address["state"] as? String, postalCode: postal, country: country
            )
        }
        return CheckoutCompletion(
            sessionID: id, kind: kind, tripID: trip,
            product: (metadata["product"] as? String).flatMap(PrintProduct.init(rawValue:)),
            email: customer?["email"] as? String, name: customer?["name"] as? String,
            shipping: shipping, cents: object["amount_total"] as? Int
        )
    }
}

/// A checkout that charges nothing, for local development and the checks
/// (`PHOTOCORE_DEV_CHECKOUT=1`). Its page completes the purchase through the
/// same path a Stripe webhook takes.
actor DevPayments: PaymentProvider {
    let base: PublicAddress
    private(set) var pending: [String: CheckoutRequest] = [:]

    init(base: PublicAddress) { self.base = base }

    func createCheckout(_ request: CheckoutRequest) async throws -> (id: String, url: String) {
        let id = "cs_dev_" + TripStore.randomToken(length: 20)
        pending[id] = request
        return (id, base.base + "/checkout/dev/" + id)
    }

    func request(_ id: String) -> CheckoutRequest? { pending[id] }

    func take(_ id: String) -> CheckoutRequest? { pending.removeValue(forKey: id) }
}

enum Payments {
    static func make(_ configuration: ServerConfiguration, address: PublicAddress) -> (any PaymentProvider)? {
        if let key = configuration.stripeSecretKey, !key.isEmpty {
            var stripe = StripePayments(secretKey: key)
            if let base = configuration.stripeAPIBase.flatMap(URL.init(string:)) { stripe.apiBase = base }
            return stripe
        }
        if configuration.devCheckout { return DevPayments(base: address) }
        return nil
    }
}
