import PhotosUI
import StoreKit
import SwiftUI

@main
struct BoundClipApp: App {
    @State private var model = ClipModel()

    var body: some Scene {
        WindowGroup {
            ClipView(model: model)
                .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { activity in
                    model.open(activity.webpageURL)
                }
                .onAppear {
                    // For trying the clip in the simulator without a domain:
                    // -BoundInviteURL http://localhost:8799/j/<code>
                    if let link = UserDefaults.standard.string(forKey: "BoundInviteURL") { model.open(URL(string: link)) }
                }
        }
    }
}

extension Color {
    static let paper = Color(UIColor { $0.userInterfaceStyle == .dark ? UIColor(red: 0.08, green: 0.07, blue: 0.06, alpha: 1) : UIColor(red: 0.969, green: 0.949, blue: 0.918, alpha: 1) })
    static let ink = Color(UIColor { $0.userInterfaceStyle == .dark ? UIColor(red: 0.94, green: 0.92, blue: 0.89, alpha: 1) : UIColor(red: 0.118, green: 0.106, blue: 0.094, alpha: 1) })
    static let ribbon = Color(UIColor { $0.userInterfaceStyle == .dark ? UIColor(red: 0.878, green: 0.420, blue: 0.380, alpha: 1) : UIColor(red: 0.702, green: 0.196, blue: 0.169, alpha: 1) })
}

struct ClipView: View {
    let model: ClipModel
    @State private var name = ""
    @State private var email = ""
    @State private var picks: [PhotosPickerItem] = []
    @State private var showingApp = false

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                cover
                Text(model.bookLine).font(.system(.title2, design: .serif, weight: .semibold)).multilineTextAlignment(.center).foregroundStyle(Color.ink)
                content
            }
            .padding(24)
            .frame(maxWidth: 520)
            .frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(Color.paper.ignoresSafeArea())
        .tint(Color.ribbon)
        .appStoreOverlay(isPresented: $showingApp) { SKOverlay.AppClipConfiguration(position: .bottom) }
    }

    private var cover: some View {
        ZStack(alignment: .bottomLeading) {
            RoundedRectangle(cornerRadius: 12).fill(Color(red: 0.118, green: 0.106, blue: 0.094))
            VStack(alignment: .leading, spacing: 4) {
                Text("A BOOK BY EVERYONE WHO WAS THERE").font(.caption2.weight(.semibold)).tracking(1.4).foregroundStyle(.white.opacity(0.7))
                Text(model.title ?? "Our trip").font(.system(size: 28, weight: .semibold, design: .serif)).foregroundStyle(.white)
            }
            .padding(20)
            Ribbon().fill(Color.ribbon).frame(width: 18, height: 44).offset(x: 190, y: 14)
        }
        .frame(width: 230, height: 270)
        .shadow(color: .black.opacity(0.2), radius: 16, y: 10)
    }

    private func join() {
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        Task { await model.join(name: name, email: email) }
    }

    @ViewBuilder private var content: some View {
        switch model.stage {
        case .waiting:
            Text("Open an invite link from a friend to add your photos.").foregroundStyle(Color.ink.opacity(0.7)).multilineTextAlignment(.center)
        case .loading:
            ProgressView()
        case .join:
            VStack(alignment: .leading, spacing: 12) {
                TextField("Your first name", text: $name).textContentType(.givenName).textFieldStyle(.roundedBorder)
                    .submitLabel(.continue).onSubmit(join)
                TextField("Email (optional), to hear when it's ready", text: $email).textContentType(.emailAddress).keyboardType(.emailAddress).textInputAutocapitalization(.never).textFieldStyle(.roundedBorder)
                    .submitLabel(.continue).onSubmit(join)
                Button(action: join) { Text("Continue").frame(maxWidth: .infinity) }
                    .buttonStyle(.borderedProminent).controlSize(.large).disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        case .ready:
            VStack(spacing: 12) {
                PhotosPicker(selection: $picks, maxSelectionCount: 300, selectionBehavior: .ordered, matching: .images, preferredItemEncoding: .current) {
                    Text("Choose your photos").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent).controlSize(.large)
                .onChange(of: picks) { _, chosen in
                    guard !chosen.isEmpty else { return }
                    let items = chosen
                    picks = []
                    Task { await model.add(items) }
                }
                Text("Pick as many as you like. Bound looks through them on this iPhone and sends only the ones the book needs. The rest never leave your phone.")
                    .font(.footnote).foregroundStyle(Color.ink.opacity(0.65)).multilineTextAlignment(.center)
                if let name = model.name { Text("Adding as \(name)").font(.footnote).foregroundStyle(Color.ink.opacity(0.55)) }
            }
        case .looking(let done, let total):
            ProgressView(value: Double(done), total: Double(max(total, 1))) { Text("Picking your best on this iPhone").font(.subheadline) }
        case .asking:
            HStack(spacing: 10) { ProgressView(); Text("Seeing what the book needs").font(.subheadline) }
        case .sending(let done, let total):
            ProgressView(value: Double(done), total: Double(max(total, 1))) { Text("Sending \(done + 1) of \(total)").font(.subheadline) }
        case .done(let sent, let picked, let chosen):
            VStack(spacing: 12) {
                Text(sent == 0 ? "Thanks! The book already has these moments." : "Thanks! \(sent == 1 ? "1 photo" : "\(sent) photos") went to the book.")
                    .font(.headline).foregroundStyle(Color.ink).multilineTextAlignment(.center)
                Text("Bound picked your best \(chosen) of \(picked) on this iPhone, then checked which moments the book still needed. \(picked - sent) never left your phone.")
                    .font(.footnote).foregroundStyle(Color.ink.opacity(0.65)).multilineTextAlignment(.center)
                Button("Add more") { model.again() }.buttonStyle(.bordered)
                Button("Get Bound for your own trips") { showingApp = true }.font(.footnote)
            }
        case .closed:
            Text("This book isn't taking photos any more.").foregroundStyle(Color.ink.opacity(0.7))
        case .failed(let message):
            VStack(spacing: 12) {
                Text(message).foregroundStyle(.red).multilineTextAlignment(.center)
                Button("Try again") { Task { await model.refresh() } }.buttonStyle(.bordered)
            }
        }
    }
}

/// The ribbon marker from the icon: a strip with a notch cut in its end.
struct Ribbon: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY - rect.width * 0.55))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}
