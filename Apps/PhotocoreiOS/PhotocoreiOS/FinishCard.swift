import PhotoEngineWorkflow
import SwiftUI

/// Why the plans sheet is showing.
struct PlansPrompt: Identifiable {
    var reason: String?
    var id: String { reason ?? "" }
}

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
    @State private var plans: PlansPrompt?
    @State private var printFile: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Finish the trip")
                .font(.display(26)).foregroundStyle(Color.ink)
            Text("Your picks edited to look their best, one book with friends\u{2019} photos and a short diary of where you went, and an Instagram set ready to post.")
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
        .sheet(item: $plans) { prompt in
            PlansSheet(reason: prompt.reason) { jws in
                guard let server else { return "Connect a server first." }
                return await finish.applyPlan(jws: jws, tripID: run.trip.id, title: run.trip.place, server: server)
            }
        }
        .onChange(of: theme) { _, picked in
            if let style = BookTheme(name: picked), !finish.limits.allows(style) {
                theme = "book"
                plans = PlansPrompt(reason: "\(style.displayName) comes with keeping the book.")
            }
        }
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
                planLine
                GroupInvite(finish: finish, server: server, tripTitle: run.trip.title, onInvite: { invite(server) }, onUpgrade: { plans = PlansPrompt(reason: $0) })
                Button(finish.people.isEmpty ? "Finish \(run.keepers.count) photos" : "Finish with everyone\u{2019}s photos") { start(server) }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(run.keepers.isEmpty && finish.friendsPhotos == 0)
                Text("Only your picks are uploaded.")
                    .font(.footnote).foregroundStyle(Color.ink.opacity(0.55))
            } else {
                Button("Connect a Bound server") { showingSettings = true }
                    .buttonStyle(PrimaryButtonStyle())
            }
        case .uploading(let done, let total):
            ProgressView(value: Double(done), total: Double(max(total, 1))) {
                Text("Uploading \(done) of \(total) picks").font(.subheadline)
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
                Button {
                    if finish.limits.editing { reading = edit } else { plans = PlansPrompt(reason: "Editing the words comes with keeping the book.") }
                } label: { Label("Edit words", systemImage: finish.limits.editing ? "pencil" : "lock") }
                    .buttonStyle(.bordered)
            }
            printRow
            if let server, finish.remote?.invitePath != nil {
                let new = finish.newSinceFinish
                if new > 0 {
                    Button("Update the book with ^[\(new) new photo](inflect: true)") { start(server) }
                        .buttonStyle(PrimaryButtonStyle())
                }
                GroupInvite(finish: finish, server: server, tripTitle: run.trip.title, onInvite: { invite(server) }, onUpgrade: { plans = PlansPrompt(reason: $0) })
                if finish.inviteOpen {
                    Toggle(isOn: Binding(get: { finish.live }, set: { on in Task { await finish.setLive(on, server: server) } })) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Update the book each night").font(.subheadline)
                            Text(finish.lastNightly.map { "Last updated \($0.formatted(.relative(presentation: .named)))." } ?? "While friends add photos, around 3 a.m.")
                                .font(.footnote).foregroundStyle(Color.ink.opacity(0.55))
                        }
                    }
                    Button("Stop taking photos") { Task { await finish.setInvite(open: false, server: server) } }
                        .font(.footnote)
                }
            }
            Text("Anyone with the book link can see it and leave notes. Only people with the invite link can add photos.")
                .font(.footnote).foregroundStyle(Color.ink.opacity(0.55))
        case .needsPlan(let message):
            Text(message).font(.subheadline).foregroundStyle(Color.ink)
            Button("See plans") { plans = PlansPrompt(reason: message) }
                .buttonStyle(PrimaryButtonStyle())
            Button("Back") { finish.reset() }
                .font(.footnote)
        case .failed(let message):
            Text(message).font(.subheadline).foregroundStyle(.red)
            Button("Try again") { if let server { start(server) } }
                .buttonStyle(.bordered)
        }
    }

    /// What this book's plan covers, and a way to more.
    @ViewBuilder private var planLine: some View {
        HStack(alignment: .firstTextBaseline) {
            Image(systemName: finish.plan == .free ? "clock" : "checkmark.seal")
                .foregroundStyle(Color.accentColor)
            Text(planText).font(.footnote).foregroundStyle(Color.ink.opacity(0.7))
            Spacer()
            if finish.plan == .free {
                Button("Keep it") { plans = PlansPrompt(reason: nil) }.font(.footnote.weight(.semibold))
            }
        }
    }

    private var planText: String {
        switch finish.plan {
        case .free:
            if let until = finish.hostedUntil {
                return "Free until \(until.formatted(.dateTime.month(.wide).day())), with up to \(finish.limits.friends) friends. Keep it for good with a Trip Pass."
            }
            return "Free for 90 days, with up to \(finish.limits.friends) friends. Keep it for good with a Trip Pass."
        case .plus: return "Yearly: kept while you subscribe, and a year after."
        case .tripPass: return "Kept for good, with everyone\u{2019}s full-size photos to download."
        case .eventPass: return "Event Pass: up to \(finish.limits.friends) friends, kept for good."
        }
    }

    /// The print-ready PDF, for Lulu, Blurb or any photo-book printer.
    @ViewBuilder private var printRow: some View {
        if let printFile {
            ShareLink(item: printFile) { Label("Share the print file", systemImage: "printer") }
                .font(.subheadline)
        } else if let server {
            Button {
                Task { printFile = await finish.printFile(server: server) }
            } label: {
                if finish.printing { ProgressView() } else { Label("Get a print-ready PDF", systemImage: "printer") }
            }
            .font(.subheadline)
            .disabled(finish.printing)
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
                    Text("Books are made on a Bound server. Only the picks you finish are uploaded to it.")
                }
            }
            .navigationTitle("Bound server")
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
