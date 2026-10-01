import PhotoEngineWorkflow
import SwiftUI

/// Everything Photocore has set aside, with restore and a deliberate, capped delete.
struct SetAsideView: View {
    @State private var log = SetAsideLog.load()
    @State private var confirmDelete = false
    @State private var working = false
    @State private var message: String?
    @Environment(\.openURL) private var openURL

    private var setAside: [String] { log.currentlySetAside() }
    private var deleted: [SetAsideLog.Entry] { log.deleted() }
    private var nextBatch: Int { min(setAside.count, SetAsidePlanner.deleteBatchLimit) }

    var body: some View {
        List {
            Section {
                if setAside.isEmpty {
                    Text("Nothing is set aside.").foregroundStyle(Color.ink.opacity(0.6))
                } else {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 3), count: 4), spacing: 3) {
                        ForEach(setAside.prefix(24), id: \.self) { identifier in
                            AssetImage(identifier: identifier).aspectRatio(1, contentMode: .fit)
                        }
                    }
                    .listRowInsets(EdgeInsets())
                    Button("Restore all \(setAside.count)") { restore() }
                        .disabled(working)
                    Button("Delete \(nextBatch)\u{2026}", role: .destructive) { confirmDelete = true }
                        .disabled(working)
                }
            } header: {
                Text("Set aside · \(setAside.count)")
            } footer: {
                Text("Set-aside photos are hidden and kept in the \u{201C}\(PhotoLibrarySafety.albumTitle)\u{201D} album. Nothing is deleted until you choose to, at most \(SetAsidePlanner.deleteBatchLimit) at a time.")
            }

            if !deleted.isEmpty {
                Section {
                    Button("Open Recently Deleted in Photos") {
                        if let url = URL(string: "photos-redirect://") { openURL(url) }
                    }
                } header: {
                    Text("Deleted · \(deleted.count)")
                } footer: {
                    Text("Deleted photos stay in Photos \u{203A} Recently Deleted for 30 days. Recover them there.")
                }
            }
        }
        .navigationTitle("Set aside")
        .alert("Delete \(nextBatch) photos?", isPresented: $confirmDelete) {
            Button("Continue", role: .destructive) { delete() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("iOS will ask you to confirm. Deleted photos move to Recently Deleted in the Photos app, where you can recover them for 30 days.")
        }
        .alert("Photocore", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(message ?? "") }
    }

    private func restore() {
        working = true
        Task {
            do {
                let ids = setAside
                try await PhotoLibrarySafety.restore(ids)
                for (trip, group) in Dictionary(grouping: ids, by: { log.latest[$0]?.tripID ?? "" }) {
                    log.record(group, tripID: trip, state: .restored)
                }
                try log.save()
            } catch {
                message = error.localizedDescription
            }
            working = false
        }
    }

    private func delete() {
        working = true
        Task {
            do {
                let removed = try await PhotoLibrarySafety.delete(setAside)
                for (trip, group) in Dictionary(grouping: removed, by: { log.latest[$0]?.tripID ?? "" }) {
                    log.record(group, tripID: trip, state: .deleted)
                }
                try log.save()
            } catch {
                // Declining the system confirmation lands here; nothing was deleted.
                message = "Nothing was deleted."
            }
            working = false
        }
    }
}
