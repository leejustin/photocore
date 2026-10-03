import Foundation
import PhotoEngineWorkflow

/// One printed copy someone paid for on the web.
struct PrintOrder: Codable, Sendable {
    enum Status: String, Codable, Sendable {
        /// Paid, not yet sent to the printer.
        case paid
        /// The printer has it.
        case submitted
        /// The printer refused it or couldn't be reached; retried later.
        case failed
        case shipped
        case cancelled
    }

    var id: String
    var tripID: String
    var slug: String
    var product: PrintProduct
    var sessionID: String
    var email: String?
    var shipping: ShippingAddress
    var status: Status
    var createdAt: Date
    var updatedAt: Date
    var cents: Int?
    /// The printer's id for the job, once submitted.
    var partnerJobID: String?
    var trackingURL: String?
    var attempts: Int?
    var error: String?
    /// The buyer's phone, which the carrier needs.
    var phone: String?
    /// The secret in the links the printer fetches the files from.
    var fileToken: String?
    /// Interior pages sent to the printer.
    var pages: Int?
}
