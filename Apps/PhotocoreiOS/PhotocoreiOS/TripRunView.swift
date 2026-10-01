import PhotoEngineCore
import PhotoEngineWorkflow
import SwiftUI

struct TripRunView: View {
    let trip: TripSummary
    @Environment(TripQueue.self) private var queue
    @State private var showingSwipe = false
    @State private var saving = false
    @State private var pendingSetAside: SetAsidePlan?
    @State private var message: String?
    @State private var planning = false
    @State private var showingPolaroids = false
    @State private var showingReel = false

    private var run: TripRun { queue.run(for: trip) }

    var body: some View {
        Group {
            switch run.stage {
            case .idle, .queued, .analyzing, .paused, .deciding:
                progress
            case .failed(let text):
                ContentUnavailableView("Couldn't finish this trip", systemImage: "exclamationmark.triangle", description: Text(text))
            case .ready:
                results
            }
        }
        .background(Color.paper)
        .navigationTitle(trip.title)
        .navigationBarTitleDisplayMode(.inline)
        .task { queue.enqueue(trip) }
        .onChange(of: run.stage) { _, stage in
            if stage == .ready, LaunchOptions.autoSwipe, !run.openMoments.isEmpty { showingSwipe = true }
        }
        .sheet(isPresented: $showingSwipe) { SwipeReviewView(run: run) }
        .sheet(isPresented: $showingPolaroids) { PolaroidSheet(run: run) }
        .sheet(isPresented: $showingReel) { ReelSheet(run: run) }
        .alert(setAsideTitle, isPresented: Binding(get: { pendingSetAside != nil }, set: { if !$0 { pendingSetAside = nil } }), presenting: pendingSetAside) { plan in
            Button("Set aside \(plan.eligible.count) photos") {
                Task {
                    do { try await run.setAside(plan) } catch { message = error.localizedDescription }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text(setAsideMessage)
        }
        .alert("Photocore", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(message ?? "")
        }
    }

    // MARK: Progress

    private var progress: some View {
        VStack(spacing: 28) {
            Spacer()
            AssetImage(identifier: trip.coverIdentifier)
                .frame(width: 220, height: 280)
                .clipShape(.rect(cornerRadius: 22))
                .shadow(color: .black.opacity(0.15), radius: 20, y: 10)
            VStack(spacing: 10) {
                Text(stageTitle).font(.display(24)).foregroundStyle(Color.ink)
                ProgressView(value: stageFraction).tint(.accentColor).frame(width: 220)
                Text(stageDetail).font(.subheadline).monospacedDigit()
                    .multilineTextAlignment(.center)
                    .foregroundStyle(Color.ink.opacity(0.6))
                    .padding(.horizontal, 32)
            }
            Spacer()
            Text("Running on this iPhone. Nothing is uploaded or copied.")
                .font(.footnote).foregroundStyle(Color.ink.opacity(0.5))
                .padding(.bottom, 24)
        }
        .frame(maxWidth: .infinity)
    }

    private var stageTitle: String {
        switch run.stage {
        case .queued: "Up next"
        case .paused: "Taking a break"
        case .deciding: "Choosing keepers"
        default: "Picking the best"
        }
    }

    private var stageFraction: Double {
        switch run.stage {
        case .analyzing(let done, let total): total > 0 ? Double(done) / Double(total) * 0.95 : 0
        case .deciding: 0.97
        default: 0
        }
    }

    private var stageDetail: String {
        switch run.stage {
        case .queued:
            if let active = queue.activeTitle { return "Starts when \(active) is done. One trip at a time keeps your iPhone cool." }
            return "Starting"
        case .analyzing(let done, let total): return "\(done) of \(total) looked at"
        case .paused(let reason): return reason
        default: return " "
        }
    }

    // MARK: Results

    private var results: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                summary
                if !run.openMoments.isEmpty {
                    Button { showingSwipe = true } label: {
                        HStack(spacing: 14) {
                            Image(systemName: "hand.draw").font(.title2)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Swipe \(run.openMoments.count) close calls").font(.headline)
                                Text("Pick between near-identical frames").font(.subheadline).opacity(0.75)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                        }
                        .padding(16)
                        .foregroundStyle(Color.ink)
                        .background(Color.accentColor.opacity(0.12), in: .rect(cornerRadius: 16))
                    }
                    .buttonStyle(.plain)
                }
                KeeperGrid(run: run)
                makeSomething
                FinishCard(run: run)
                othersSection
            }
            .padding(20)
            .padding(.bottom, 90)
        }
        .safeAreaInset(edge: .bottom) {
            Button {
                saving = true
                Task {
                    do { try await run.saveAlbum() } catch { message = "Could not save the album. \(error.localizedDescription)" }
                    saving = false
                }
            } label: {
                if saving {
                    ProgressView().tint(.white)
                } else if run.albumSaved {
                    Label("Saved to Photos", systemImage: "checkmark")
                } else {
                    Text("Save \(run.keepers.count) to a Photos album")
                }
            }
            .buttonStyle(SecondaryButtonStyle())
            .disabled(run.keepers.isEmpty || saving || run.albumSaved)
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(.ultraThinMaterial)
        }
    }

    /// Free things to make from the keepers, all on this iPhone.
    private var makeSomething: some View {
        HStack(spacing: 12) {
            makeTile("Polaroids", "photo.on.rectangle.angled", "Prints to save or share") { showingPolaroids = true }
            makeTile("Highlight reel", "film", "A short video of the trip") { showingReel = true }
        }
        .disabled(run.keepers.isEmpty)
    }

    private func makeTile(_ title: String, _ symbol: String, _ detail: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                Image(systemName: symbol).font(.title2).foregroundStyle(Color.accentColor)
                Text(title).font(.headline).foregroundStyle(Color.ink)
                Text(detail).font(.caption).foregroundStyle(Color.ink.opacity(0.6))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(Color.ink.opacity(0.05), in: .rect(cornerRadius: 16))
        }
        .buttonStyle(.plain)
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("\(run.keepers.count) keepers").font(.display(34)).foregroundStyle(Color.ink)
            Text(summaryLine).font(.subheadline).foregroundStyle(Color.ink.opacity(0.6))
        }
    }

    private var summaryLine: String {
        var parts = ["from \(run.totalPhotos) photos"]
        if run.skippedUtility > 0 { parts.append("\(run.skippedUtility) receipts and documents left alone") }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder private var othersSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("The other \(run.others.count)")
                .font(.footnote.weight(.semibold)).textCase(.uppercase).tracking(1)
                .foregroundStyle(Color.ink.opacity(0.5))
            if run.setAsideCount > 0 {
                Text("\(run.setAsideCount) gathered in the \u{201C}\(PhotoLibrarySafety.albumTitle)\u{201D} album. Nothing was deleted. Review and delete them from the archive button on the home screen when you're ready.")
                    .font(.subheadline).foregroundStyle(Color.ink.opacity(0.7))
                if run.protectedCount > 0 {
                    Text("\(run.protectedCount) favorites, edited, shared or album photos were left where they are.")
                        .font(.footnote).foregroundStyle(Color.ink.opacity(0.55))
                }
                Button("Restore all \(run.setAsideCount)") {
                    Task { do { try await run.restoreAll() } catch { message = error.localizedDescription } }
                }
                .buttonStyle(.bordered)
            } else {
                Text("They stay in your library. To tidy up, set them aside: they're gathered in one album to look over, and deleting is a separate step you confirm.")
                    .font(.subheadline).foregroundStyle(Color.ink.opacity(0.7))
                Button {
                    guard !planning else { return }
                    planning = true
                    Task {
                        pendingSetAside = await run.setAsidePlan()
                        planning = false
                    }
                } label: {
                    if planning { ProgressView() } else { Text("Set aside the others\u{2026}") }
                }
                .buttonStyle(.bordered)
                .disabled(run.others.isEmpty || planning)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.ink.opacity(0.04), in: .rect(cornerRadius: 16))
    }

    private var setAsideTitle: String { "Set aside \(pendingSetAside?.eligible.count ?? 0) photos?" }

    private var setAsideMessage: String {
        guard let plan = pendingSetAside else { return "" }
        var text = "They'll be gathered in the \u{201C}\(PhotoLibrarySafety.albumTitle)\u{201D} album. Nothing changes in your library, and you can undo it anytime."
        if !plan.protected.isEmpty {
            text += " \(plan.protected.count) favorites, edited, shared or album photos will be left alone."
        }
        return text
    }
}

struct KeeperGrid: View {
    let run: TripRun
    private let columns = [GridItem(.flexible(), spacing: 4), GridItem(.flexible(), spacing: 4), GridItem(.flexible(), spacing: 4)]

    var body: some View {
        LazyVGrid(columns: columns, spacing: 4) {
            ForEach(run.keepers, id: \.id) { photo in
                if let identifier = run.identifier(photo.id) {
                    AssetImage(identifier: identifier)
                        .aspectRatio(1, contentMode: .fit)
                        .clipShape(.rect(cornerRadius: 6))
                        .contextMenu {
                            Button("Remove from keepers", systemImage: "minus.circle") { run.toggle(photo.id) }
                        }
                }
            }
        }
    }
}
