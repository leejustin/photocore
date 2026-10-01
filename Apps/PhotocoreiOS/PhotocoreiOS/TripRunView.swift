import PhotoEngineCore
import PhotoEngineWorkflow
import SwiftUI

struct TripRunView: View {
    let trip: TripSummary
    @State private var run: TripRun
    @State private var showingSwipe = false
    @State private var saving = false

    init(trip: TripSummary) {
        self.trip = trip
        _run = State(initialValue: TripRun(trip: trip))
    }

    var body: some View {
        Group {
            switch run.stage {
            case .idle, .reading, .culling:
                progress
            case .failed(let message):
                ContentUnavailableView("Something went wrong", systemImage: "exclamationmark.triangle", description: Text(message))
            case .ready, .saved:
                results
            }
        }
        .background(Color.paper)
        .navigationTitle(trip.title)
        .navigationBarTitleDisplayMode(.inline)
        .task { run.start() }
        .onDisappear { if case .ready = run.stage {} else { run.cancel() } }
        .onChange(of: run.stage) { _, stage in
            if stage == .ready, LaunchOptions.autoSwipe, !run.openMoments.isEmpty { showingSwipe = true }
        }
        .sheet(isPresented: $showingSwipe) {
            SwipeReviewView(run: run)
        }
    }

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
                Text(stageDetail).font(.subheadline).monospacedDigit().foregroundStyle(Color.ink.opacity(0.6))
            }
            Spacer()
            Text("Running on this iPhone. Nothing is uploaded.")
                .font(.footnote).foregroundStyle(Color.ink.opacity(0.5))
                .padding(.bottom, 24)
        }
        .frame(maxWidth: .infinity)
    }

    private var stageTitle: String {
        switch run.stage {
        case .reading: "Reading your trip"
        case .culling: "Picking the best"
        default: "Getting ready"
        }
    }

    private var stageFraction: Double {
        switch run.stage {
        case .reading(let done, let total): total > 0 ? Double(done) / Double(total) * 0.3 : 0
        case .culling(let done, let total): total > 0 ? 0.3 + Double(done) / Double(total) * 0.7 : 0.3
        default: 0
        }
    }

    private var stageDetail: String {
        switch run.stage {
        case .reading(let done, let total): "\(done) of \(total) photos"
        case .culling(let done, let total): "\(done) of \(total) looked at"
        default: " "
        }
    }

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
                if case .saved(let title) = run.stage {
                    Label("Saved to Photos as \u{201C}\(title)\u{201D}", systemImage: "checkmark.circle.fill")
                        .font(.subheadline).foregroundStyle(Color.ink)
                }
            }
            .padding(20)
            .padding(.bottom, 90)
        }
        .safeAreaInset(edge: .bottom) {
            Button {
                saving = true
                Task { await run.saveAlbum(); saving = false }
            } label: {
                if saving {
                    ProgressView().tint(.white)
                } else if isSaved {
                    Label("Saved to Photos", systemImage: "checkmark")
                } else {
                    Text("Save \(run.keepers.count) to a Photos album")
                }
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(run.keepers.isEmpty || saving || isSaved)
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(.ultraThinMaterial)
        }
    }

    private var isSaved: Bool {
        if case .saved = run.stage { true } else { false }
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("\(run.keepers.count) keepers")
                .font(.display(34)).foregroundStyle(Color.ink)
            Text(summaryLine)
                .font(.subheadline).foregroundStyle(Color.ink.opacity(0.6))
        }
    }

    private var summaryLine: String {
        var parts = ["from \(run.totalPhotos) photos"]
        if run.skippedUtility > 0 {
            parts.append("\(run.skippedUtility) receipts and documents set aside")
        }
        return parts.joined(separator: " · ")
    }
}

struct KeeperGrid: View {
    let run: TripRun
    private let columns = [GridItem(.flexible(), spacing: 4), GridItem(.flexible(), spacing: 4), GridItem(.flexible(), spacing: 4)]

    var body: some View {
        LazyVGrid(columns: columns, spacing: 4) {
            ForEach(run.keepers, id: \.id) { photo in
                FileImage(url: photo.asset.url, maxPixel: 400)
                    .aspectRatio(1, contentMode: .fit)
                    .clipShape(.rect(cornerRadius: 6))
                    .contextMenu {
                        Button("Remove from keepers", systemImage: "minus.circle") { run.toggle(photo.id) }
                    }
            }
        }
    }
}
