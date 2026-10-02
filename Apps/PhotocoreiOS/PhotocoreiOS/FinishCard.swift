import SwiftUI

/// The upsell: one keeper shown before and after the paid finish, then upload,
/// finish and share. Appears after the free cull.
struct FinishCard: View {
    let run: TripRun
    @State private var finish = TripFinish()
    @State private var showAfter = true
    @State private var showingSettings = false
    @State private var server = FinishServer.saved
    @State private var note = ""
    @State private var events: [String] = []
    @State private var reading: URL?
    @State private var theme = "book"

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Finish the trip")
                .font(.display(26)).foregroundStyle(Color.ink)
            Text("Every keeper edited to look its best, a shared book with a short diary of where you went, and an Instagram set ready to post.")
                .font(.subheadline).foregroundStyle(Color.ink.opacity(0.7))
            preview
            content
        }
        .padding(18)
        .background(Color.paper)
        .clipShape(.rect(cornerRadius: 20))
        .overlay(RoundedRectangle(cornerRadius: 20).stroke(Color.accentColor.opacity(0.35), lineWidth: 1.5))
        .sheet(isPresented: $showingSettings, onDismiss: { server = FinishServer.saved }) { ServerSettingsView() }
        .sheet(item: $reading) { SafariView(url: $0).ignoresSafeArea() }
        .onAppear { finish.restore(tripID: run.trip.id) }
        .task(id: server) {
            guard let server, let first = run.keepers.first, let identifier = run.identifier(first.id) else { return }
            await finish.loadPreview(identifier: identifier, server: server)
        }
    }

    @ViewBuilder private var preview: some View {
        if let before = finish.before {
            ZStack(alignment: .bottomLeading) {
                Image(uiImage: (showAfter ? finish.after : nil) ?? before)
                    .resizable().aspectRatio(contentMode: .fill)
                    .frame(maxWidth: .infinity).frame(height: 220)
                    .clipShape(.rect(cornerRadius: 14))
                    .animation(.easeInOut(duration: 0.25), value: showAfter)
                if finish.after != nil {
                    Picker("", selection: $showAfter) {
                        Text("Before").tag(false)
                        Text("After").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 180)
                    .padding(4)
                    .background(.regularMaterial, in: .capsule)
                    .padding(10)
                }
            }
        }
    }

    @ViewBuilder private var content: some View {
        switch finish.stage {
        case .idle:
            if let server {
                TripContextPicker(trip: run.trip, note: $note, events: $events)
                Picker("Style", selection: $theme) {
                    Text("Book").tag("book")
                    Text("Snapshots").tag("snapshot")
                }
                .pickerStyle(.segmented)
                GroupInvite(finish: finish, server: server, tripTitle: run.trip.title) { invite(server) }
                Button(finish.people.isEmpty ? "Finish \(run.keepers.count) photos" : "Finish with everyone\u{2019}s photos") { start(server) }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(run.keepers.isEmpty && finish.friendsPhotos == 0)
                Text("Only your keepers are uploaded. Test build: no charge.")
                    .font(.footnote).foregroundStyle(Color.ink.opacity(0.55))
            } else {
                Button("Connect a Photocore server") { showingSettings = true }
                    .buttonStyle(PrimaryButtonStyle())
            }
        case .uploading(let done, let total):
            ProgressView(value: Double(done), total: Double(max(total, 1))) {
                Text("Uploading \(done) of \(total) keepers").font(.subheadline)
            }
        case .finishing(let message):
            HStack(spacing: 10) {
                ProgressView()
                Text(message).font(.subheadline).foregroundStyle(Color.ink.opacity(0.7))
            }
        case .done(let book, let edit):
            Button { reading = book } label: {
                Label("Read your book", systemImage: "book")
            }
            .buttonStyle(PrimaryButtonStyle())
            HStack {
                ShareLink(item: book, subject: Text(run.trip.title), message: Text("Our trip, the best photos and a little diary.")) {
                    Label("Share", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.bordered)
                Button { reading = edit } label: { Label("Edit words", systemImage: "pencil") }
                    .buttonStyle(.bordered)
            }
            if let server, finish.remote?.invitePath != nil {
                let new = finish.friendsPhotos - (finish.photosAtLastFinish ?? 0)
                if new > 0 {
                    Button("Update the book with ^[\(new) new photo](inflect: true)") { start(server) }
                        .buttonStyle(PrimaryButtonStyle())
                }
                GroupInvite(finish: finish, server: server, tripTitle: run.trip.title) { invite(server) }
                if finish.inviteOpen {
                    Button("Stop taking photos") { Task { await finish.setInvite(open: false, server: server) } }
                        .font(.footnote)
                }
            }
            Text("Anyone with the book link can see it and leave notes. Only people with the invite link can add photos.")
                .font(.footnote).foregroundStyle(Color.ink.opacity(0.55))
        case .failed(let message):
            Text(message).font(.subheadline).foregroundStyle(.red)
            Button("Try again") { if let server { start(server) } }
                .buttonStyle(.bordered)
        }
    }

    private func invite(_ server: FinishServer) {
        Task {
            await finish.invite(tripID: run.trip.id, title: run.trip.place, note: note, events: events, theme: theme, server: server)
        }
    }

    private func start(_ server: FinishServer) {
        let ids = run.keepers.compactMap { run.identifier($0.id) }
        Task {
            await finish.finish(tripID: run.trip.id, title: run.trip.place, note: note, events: events, theme: theme, identifiers: ids, server: server)
        }
    }
}

struct ServerSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var url = UserDefaults.standard.string(forKey: "PhotocoreServerURL") ?? ""
    @State private var token = UserDefaults.standard.string(forKey: "PhotocoreServerToken") ?? ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("https://photocore.example.ts.net", text: $url)
                        .textInputAutocapitalization(.never).keyboardType(.URL).autocorrectionDisabled()
                    SecureField("Server token", text: $token)
                } footer: {
                    Text("The paid finish runs on a Photocore server. Only the keepers you choose are uploaded to it.")
                }
            }
            .navigationTitle("Photocore server")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        FinishServer.save(url: url, token: token)
                        dismiss()
                    }
                    .disabled(URL(string: url) == nil || token.isEmpty)
                }
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
    }
}
