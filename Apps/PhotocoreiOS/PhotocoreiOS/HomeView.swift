import SwiftUI

struct HomeView: View {
    @State private var library = TripLibrary()
    @State private var path = NavigationPath()
    @Environment(TripQueue.self) private var queue

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    header
                    content
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 40)
            }
            .background(Color.paper)
            .navigationDestination(for: TripSummary.self) { trip in
                TripRunView(trip: trip)
            }
            .navigationDestination(for: String.self) { _ in
                SetAsideView()
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink(value: "set-aside") {
                        Image(systemName: "archivebox")
                    }
                    .accessibilityLabel("Set aside")
                }
            }
            .refreshable { await library.reload() }
        }
        .tint(.accentColor)
        .task {
            await library.start()
            if LaunchOptions.autoOpenFirstTrip, let first = library.trips.first, path.isEmpty {
                path.append(first)
            }
        }
    }

    private func status(for trip: TripSummary) -> String? {
        if BookStore.book(for: trip.id) != nil { return "Book ready" }
        guard let run = queue.runs[trip.id] else { return nil }
        switch run.stage {
        case .queued: return "Up next"
        case .analyzing, .deciding, .paused: return "Culling"
        case .ready: return "\(run.keepers.count) kept"
        default: return nil
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Finish the trip.")
                .font(.display(38))
                .foregroundStyle(Color.ink)
            Text("Photocore picks the best photos from each trip. Culling runs on this iPhone; nothing leaves it unless you choose to finish a trip into a book.")
                .font(.body)
                .foregroundStyle(Color.ink.opacity(0.65))
        }
        .padding(.top, 24)
    }

    @ViewBuilder private var content: some View {
        switch library.access {
        case .denied:
            AccessCard()
        case .unknown where !library.isLoading:
            ProgressView().frame(maxWidth: .infinity).padding(.top, 40)
        default:
            if library.isLoading && library.trips.isEmpty {
                ProgressView("Looking for trips").frame(maxWidth: .infinity).padding(.top, 40)
            } else if library.trips.isEmpty {
                Text("No trips yet. A trip is twenty or more photos taken over a day or a few.")
                    .foregroundStyle(Color.ink.opacity(0.6))
            } else {
                Text("Your trips")
                    .font(.footnote.weight(.semibold))
                    .textCase(.uppercase)
                    .tracking(1)
                    .foregroundStyle(Color.ink.opacity(0.5))
                ForEach(library.trips) { trip in
                    NavigationLink(value: trip) { TripCard(trip: trip, status: status(for: trip)) }
                        .buttonStyle(.plain)
                }
            }
        }
    }
}

struct TripCard: View {
    let trip: TripSummary
    var status: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            AssetImage(identifier: trip.coverIdentifier)
                .aspectRatio(16 / 10, contentMode: .fit)
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(trip.title).font(.display(20)).foregroundStyle(Color.ink)
                    Text(trip.subtitle).font(.subheadline).foregroundStyle(Color.ink.opacity(0.6))
                }
                Spacer()
                if let status {
                    Text(status)
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(Color.accentColor.opacity(0.14), in: .capsule)
                        .foregroundStyle(Color.ink)
                }
                Image(systemName: "chevron.right").foregroundStyle(Color.ink.opacity(0.35))
            }
            .padding(16)
        }
        .background(Color.paper)
        .clipShape(.rect(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(Color.ink.opacity(0.08)))
        .shadow(color: .black.opacity(0.06), radius: 12, y: 6)
    }
}

struct AccessCard: View {
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Photocore needs your photos").font(.display(22))
            Text("Allow access in Settings so Photocore can find your trips. Culling happens on this iPhone.")
                .foregroundStyle(Color.ink.opacity(0.65))
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
            }
            .buttonStyle(PrimaryButtonStyle())
        }
        .padding(20)
        .background(Color.ink.opacity(0.04), in: .rect(cornerRadius: 18))
    }
}
