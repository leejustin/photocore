import SwiftUI

/// "Were friends there too?": one link that lets everyone add their photos, and
/// who has so far. Friends need no app; the link opens a page in any browser.
struct GroupInvite: View {
    let finish: TripFinish
    let server: FinishServer
    let tripTitle: String
    /// Creates the trip on the server so the link exists.
    let onInvite: () -> Void
    /// Opens the plans, with the reason.
    let onUpgrade: (String) -> Void
    @State private var ownerName = OwnerName.saved

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Were friends there too?", systemImage: "person.2")
                .font(.headline).foregroundStyle(Color.ink)
            if let link = finish.inviteURL(server) {
                ShareLink(item: link, subject: Text(tripTitle), message: Text("Add your photos from \(tripTitle) so we can make one book together.")) {
                    Label("Send the invite link", systemImage: "link")
                }
                .buttonStyle(SecondaryButtonStyle())
                people
                capacity
                if !finish.inviteOpen {
                    Text("The link is closed, so no one can add more.")
                        .font(.footnote).foregroundStyle(Color.ink.opacity(0.55))
                }
            } else {
                Text("Send them a link to add their photos. Photocore keeps the best shot of each moment and credits who took it.")
                    .font(.subheadline).foregroundStyle(Color.ink.opacity(0.7))
                TextField("Your first name, for photo credits", text: $ownerName)
                    .textContentType(.givenName)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: ownerName) { OwnerName.saved = ownerName }
                Button {
                    onInvite()
                } label: {
                    if finish.inviting { ProgressView() } else { Text("Invite friends") }
                }
                .buttonStyle(SecondaryButtonStyle())
                .disabled(finish.inviting)
                if let error = finish.inviteError {
                    Text(error).font(.footnote).foregroundStyle(.red)
                }
            }
        }
        .padding(14)
        .background(Color.accentColor.opacity(0.06), in: .rect(cornerRadius: 14))
        .task {
            // Keep the list fresh while the card is on screen, including right
            // after the link is made.
            while !Task.isCancelled {
                if finish.remote != nil { await finish.refreshPeople(server: server) }
                try? await Task.sleep(for: .seconds(10))
            }
        }
    }

    /// How much room the plan leaves, and a way to more when it runs low.
    @ViewBuilder private var capacity: some View {
        let joined = finish.people.count
        let room = finish.limits.friends
        if joined >= room - 1 {
            HStack {
                Text(joined >= room ? "The book is full: \(room) of \(room) friends." : "Room for one more friend.")
                    .font(.footnote).foregroundStyle(Color.ink.opacity(0.7))
                Spacer()
                if finish.plan == .free || finish.plan == .plus || finish.plan == .tripPass {
                    Button("More room") {
                        onUpgrade(finish.plan == .free ? "The free book takes \(room) friends. Plus and the Trip Pass take 25; the Event Pass takes 100." : "The Event Pass takes up to 100 guests.")
                    }
                    .font(.footnote.weight(.semibold))
                }
            }
        }
    }

    @ViewBuilder private var people: some View {
        if finish.people.isEmpty {
            Text("No one has added photos yet. Their photos are picked when you finish.")
                .font(.footnote).foregroundStyle(Color.ink.opacity(0.6))
        } else {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(finish.people) { person in
                    HStack {
                        Image(systemName: "person.crop.circle.fill").foregroundStyle(Color.accentColor.opacity(0.7))
                        Text(person.name).foregroundStyle(Color.ink)
                        Spacer()
                        Text("^[\(person.photos) photo](inflect: true)").foregroundStyle(Color.ink.opacity(0.6))
                    }
                    .font(.subheadline)
                }
            }
        }
    }
}
