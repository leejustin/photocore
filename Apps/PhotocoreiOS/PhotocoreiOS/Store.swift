import Foundation
import Observation
import PhotoEngineWorkflow
import StoreKit

/// The App Store side of the plans, with StoreKit 2. The app never decides
/// what a purchase unlocks: it hands the App Store's signed transaction to the
/// server, which checks the signature and applies the plan to one book.
@MainActor
@Observable
final class Store {
    static let shared = Store()

    /// The signed transaction of an active Plus subscription, if any.
    private(set) var plus: String?
    /// Passes bought but not yet spent on a book (for example, the app closed
    /// before the server confirmed). They're finished once a book uses them.
    private(set) var unspentPasses: [UnspentPass] = []

    struct UnspentPass: Identifiable, Equatable {
        var id: UInt64
        var product: PlanProduct
        var jws: String
    }

    private var updates: Task<Void, Never>?

    private init() {}

    /// Starts listening for purchases made elsewhere (renewals, Ask to Buy,
    /// another device) and loads what's already owned. Call once at launch.
    func start() {
        guard updates == nil else { return }
        updates = Task { [weak self] in
            for await result in Transaction.updates {
                await self?.take(result)
            }
        }
        Task { await refresh() }
    }

    func refresh() async {
        var activePlus: String?
        for await result in Transaction.currentEntitlements {
            if case .verified(let transaction) = result, transaction.productType == .autoRenewable,
               transaction.revocationDate == nil, (transaction.expirationDate ?? .distantFuture) > Date() {
                activePlus = result.jwsRepresentation
            }
        }
        plus = activePlus
        var passes: [UnspentPass] = []
        for await result in Transaction.unfinished {
            if case .verified(let transaction) = result, let product = PlanProduct(rawValue: transaction.productID), product.isPass,
               transaction.revocationDate == nil {
                passes.append(UnspentPass(id: transaction.id, product: product, jws: result.jwsRepresentation))
            }
        }
        unspentPasses = passes
    }

    /// Records a completed purchase and returns its signed transaction for the server.
    @discardableResult
    func take(_ result: VerificationResult<Transaction>) async -> String? {
        guard case .verified(let transaction) = result else { return nil }
        if transaction.productType == .autoRenewable {
            // Subscriptions are finished right away; the server checks expiry itself.
            await transaction.finish()
        }
        await refresh()
        return result.jwsRepresentation
    }

    /// Called once the server has put a pass on a book.
    func spent(jws: String) async {
        for await result in Transaction.unfinished where result.jwsRepresentation == jws {
            if case .verified(let transaction) = result { await transaction.finish() }
        }
        await refresh()
    }

    func restore() async {
        try? await AppStore.sync()
        await refresh()
    }
}
