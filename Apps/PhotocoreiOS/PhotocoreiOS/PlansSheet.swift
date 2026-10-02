import PhotoEngineWorkflow
import StoreKit
import SwiftUI

/// The upgrade, built from StoreKit's own product views so prices, the
/// purchase sheet and Family Sharing come from the system. A completed
/// purchase is handed to `onPurchase` as a signed transaction for the server.
struct PlansSheet: View {
    /// Why the sheet opened, in the words the person needs ("Your free book is made").
    let reason: String?
    /// Applies a purchase to the book; returns nil on success or a reason.
    let onPurchase: (String) async -> String?
    @Environment(\.dismiss) private var dismiss
    @State private var applying = false
    @State private var message: String?
    private let store = Store.shared

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if let reason {
                        Text(reason).font(.subheadline).foregroundStyle(Color.ink.opacity(0.75))
                    }
                    if !store.unspentPasses.isEmpty {
                        unspent
                    }
                    section("Plus", "Every trip, all year") {
                        features(["Up to 12 books a year", "25 friends and 500 of their photos per book", "Snapshots style, the Instagram set and editing", "No Photocore footer"])
                        ProductView(id: PlanProduct.plusYearly.rawValue) { icon("sparkles") }
                        ProductView(id: PlanProduct.plusMonthly.rawValue) { icon("calendar") }
                    }
                    section("Just this trip", "Pay once, keep it for good") {
                        ProductView(id: PlanProduct.tripPass.rawValue) { icon("book.closed") }
                        ProductView(id: PlanProduct.eventPass.rawValue) { icon("person.3") }
                        Text("The Event Pass is for weddings and big parties: up to 100 guests.")
                            .font(.footnote).foregroundStyle(Color.ink.opacity(0.6))
                    }
                    if let message {
                        Text(message).font(.footnote).foregroundStyle(.red)
                    }
                    Text("Friends never pay to see a book or add their photos. Your library stays on your phone; only the keepers you finish are uploaded.")
                        .font(.footnote).foregroundStyle(Color.ink.opacity(0.55))
                    HStack {
                        Button("Restore Purchases") { Task { await store.restore() } }
                        Spacer()
                        Link("Terms", destination: URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!)
                    }
                    .font(.footnote)
                }
                .padding(20)
            }
            .background(Color.paper)
            .navigationTitle("Make more books")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Not now") { dismiss() } } }
            .overlay { if applying { ProgressView("Adding it to your book").padding().background(.regularMaterial, in: .rect(cornerRadius: 12)) } }
            // Ties purchases to this install, for App Store notifications later.
            .inAppPurchaseOptions { _ in [.appAccountToken(InstallIdentity.id)] }
            .onInAppPurchaseCompletion { _, result in
                guard case .success(.success(let verification)) = result, let jws = await store.take(verification) else { return }
                await apply(jws)
            }
        }
    }

    private func apply(_ jws: String) async {
        applying = true
        defer { applying = false }
        if let problem = await onPurchase(jws) {
            message = problem
        } else {
            dismiss()
        }
    }

    @ViewBuilder private var unspent: some View {
        section("Ready to use", "Bought earlier, not used yet") {
            ForEach(store.unspentPasses) { pass in
                Button("Use your \(pass.product.plan.displayName) on this book") { Task { await apply(pass.jws) } }
                    .buttonStyle(PrimaryButtonStyle())
            }
        }
    }

    private func section<Content: View>(_ title: String, _ subtitle: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.display(22)).foregroundStyle(Color.ink)
            Text(subtitle).font(.subheadline).foregroundStyle(Color.ink.opacity(0.6))
            content()
        }
        .padding(16)
        .background(Color.accentColor.opacity(0.06), in: .rect(cornerRadius: 16))
    }

    private func features(_ items: [String]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(items, id: \.self) { item in
                Label(item, systemImage: "checkmark").font(.subheadline).foregroundStyle(Color.ink)
            }
        }
    }

    private func icon(_ name: String) -> some View {
        Image(systemName: name).font(.title2).foregroundStyle(Color.accentColor)
    }
}
