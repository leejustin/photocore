import Photos
import PhotoEngineCore
import SwiftUI

/// One instant print: a square photo in a white frame with a handwritten caption.
struct SnapshotCard: View {
    let image: UIImage
    let caption: String
    var width: CGFloat = 300

    var body: some View {
        VStack(spacing: 0) {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: width - 28, height: width - 28)
                .clipped()
                .saturation(0.92)
                .contrast(0.97)
            Text(caption)
                .font(.custom("Bradley Hand", size: width * 0.07))
                .foregroundStyle(Color(red: 0.2, green: 0.19, blue: 0.17))
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .frame(maxWidth: .infinity, minHeight: width * 0.2)
        }
        .padding([.top, .horizontal], 14)
        .frame(width: width)
        .background(Color(red: 0.99, green: 0.988, blue: 0.972))
    }
}

/// Turns a trip's keepers into snapshot prints that can be saved to Photos or
/// shared, using SwiftUI's ImageRenderer. No server, no upload.
struct SnapshotSheet: View {
    let run: TripRun
    @Environment(\.dismiss) private var dismiss
    @State private var images: [(id: PhotoID, image: UIImage)] = []
    @State private var exported: [URL] = []
    @State private var saving = false
    @State private var message: String?

    private var caption: String { run.trip.place ?? run.trip.dates }
    private let columns = [GridItem(.flexible(), spacing: 18), GridItem(.flexible(), spacing: 18)]

    var body: some View {
        NavigationStack {
            ScrollView {
                if images.isEmpty {
                    ProgressView("Printing").padding(.top, 80)
                }
                LazyVGrid(columns: columns, spacing: 26) {
                    ForEach(Array(images.enumerated()), id: \.element.id) { index, item in
                        SnapshotCard(image: item.image, caption: caption, width: 160)
                            .rotationEffect(.degrees([-2.2, 1.6, -0.8, 2.4][index % 4]))
                            .shadow(color: .black.opacity(0.18), radius: 10, y: 6)
                    }
                }
                .padding(22)
            }
            .background(Color(red: 0.94, green: 0.91, blue: 0.86))
            .navigationTitle("Snapshots")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    if !exported.isEmpty {
                        ShareLink(items: exported) { Image(systemName: "square.and.arrow.up") }
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                Button {
                    Task { await save() }
                } label: {
                    if saving { ProgressView().tint(.white) } else { Text("Save \(images.count) to Photos") }
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(images.isEmpty || saving)
                .padding(.horizontal, 20).padding(.vertical, 12)
                .background(.ultraThinMaterial)
            }
            .alert("Photocore", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(message ?? "") }
            .task { await load() }
        }
    }

    private func load() async {
        for photo in run.keepers {
            guard let identifier = run.identifier(photo.id),
                  let data = await TripFinish.jpeg(identifier: identifier, maxPixel: 1400),
                  let image = UIImage(data: data) else { continue }
            images.append((photo.id, image))
        }
        exported = images.compactMap { render($0.image) }
    }

    /// A full-size print, about 1080 pixels wide, written to a temporary PNG.
    private func render(_ image: UIImage) -> URL? {
        let renderer = ImageRenderer(content: SnapshotCard(image: image, caption: caption, width: 360))
        renderer.scale = 3
        guard let output = renderer.uiImage, let png = output.pngData() else { return nil }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("snapshot-\(UUID().uuidString).png")
        return (try? png.write(to: url)) != nil ? url : nil
    }

    /// Photos runs the change block on its own queue, so it must not be tied to
    /// the main actor (a view's closures are, and that crashed).
    nonisolated static func saveImages(_ urls: [URL], albumTitle: String) async throws {
        try await PHPhotoLibrary.shared().performChanges {
            let album = PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: albumTitle)
            var placeholders: [PHObjectPlaceholder] = []
            for url in urls {
                if let request = PHAssetChangeRequest.creationRequestForAssetFromImage(atFileURL: url),
                   let placeholder = request.placeholderForCreatedAsset {
                    placeholders.append(placeholder)
                }
            }
            album.addAssets(placeholders as NSArray)
        }
    }

    private func save() async {
        saving = true
        defer { saving = false }
        let urls = exported
        let title = "Photocore · Snapshots · " + run.trip.title
        do {
            try await Self.saveImages(urls, albumTitle: title)
            message = "Saved \(urls.count) snapshots to the \u{201C}\(title)\u{201D} album."
        } catch {
            message = "Couldn't save the snapshots. \(error.localizedDescription)"
        }
    }
}
