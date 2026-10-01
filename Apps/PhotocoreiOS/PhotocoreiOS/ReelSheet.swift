import AVKit
import Photos
import PhotoEngineApple
import SwiftUI

/// Makes a short vertical highlight reel from the keepers, on this iPhone, with
/// AVFoundation. Live Photos bring their motion; stills get a slow push-in.
struct ReelSheet: View {
    let run: TripRun
    @Environment(\.dismiss) private var dismiss
    @State private var stage = "Gathering your keepers"
    @State private var reel: URL?
    @State private var player: AVPlayer?
    @State private var failed: String?
    @State private var saved = false

    static let clipLimit = 14

    var body: some View {
        NavigationStack {
            VStack(spacing: 18) {
                if let player {
                    VideoPlayer(player: player)
                        .aspectRatio(9 / 16, contentMode: .fit)
                        .clipShape(.rect(cornerRadius: 18))
                        .onAppear { player.play() }
                } else if let failed {
                    ContentUnavailableView("Couldn't make the reel", systemImage: "film", description: Text(failed))
                } else {
                    Spacer()
                    ProgressView()
                    Text(stage).font(.subheadline).foregroundStyle(Color.ink.opacity(0.6))
                    Spacer()
                }
                if let reel {
                    HStack(spacing: 12) {
                        Button {
                            Task { await save(reel) }
                        } label: {
                            Label(saved ? "Saved" : "Save to Photos", systemImage: saved ? "checkmark" : "square.and.arrow.down")
                        }
                        .buttonStyle(PrimaryButtonStyle())
                        .disabled(saved)
                        ShareLink(item: reel) {
                            Label("Share", systemImage: "square.and.arrow.up")
                        }
                        .buttonStyle(SecondaryButtonStyle())
                    }
                }
            }
            .padding(20)
            .background(Color.paper)
            .navigationTitle("Highlight reel")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
            .task { await build() }
        }
    }

    private func build() async {
        var clips: [ReelClip] = []
        for photo in run.keepers.prefix(Self.clipLimit) {
            guard let identifier = run.identifier(photo.id),
                  let asset = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil).firstObject else { continue }
            stage = "Gathering your keepers · \(clips.count + 1) of \(min(run.keepers.count, Self.clipLimit))"
            if asset.mediaSubtypes.contains(.photoLive), let motion = await Self.liveMotion(asset) {
                clips.append(ReelClip(.video(motion)))
            } else if let data = await TripFinish.jpeg(identifier: identifier, maxPixel: 1920),
                      let source = CGImageSourceCreateWithData(data as CFData, nil),
                      let image = CGImageSourceCreateImageAtIndex(source, 0, nil) {
                clips.append(ReelClip(.still(image), focus: SaliencyCropper.salientRegion(in: image)))
            }
        }
        guard !clips.isEmpty else { failed = "None of the keepers could be read."; return }
        stage = "Making the reel"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("reel-\(run.trip.id).mp4")
        let options = HighlightReel.Options(title: run.trip.title, subtitle: run.trip.place == nil ? nil : run.trip.dates)
        do {
            let result = try await HighlightReel.render(clips: clips, to: url, options: options)
            reel = result.url
            player = AVPlayer(url: result.url)
        } catch {
            failed = error.localizedDescription
        }
    }

    /// A Live Photo's short video, written to a temporary file.
    static func liveMotion(_ asset: PHAsset) async -> URL? {
        guard let resource = PHAssetResource.assetResources(for: asset).first(where: { $0.type == .pairedVideo }) else { return nil }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("live-\(UUID().uuidString).mov")
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = true
        do {
            try await PHAssetResourceManager.default().writeData(for: resource, toFile: url, options: options)
            return url
        } catch {
            return nil
        }
    }

    nonisolated static func saveVideo(_ url: URL) async throws {
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
        }
    }

    private func save(_ url: URL) async {
        do {
            try await Self.saveVideo(url)
            saved = true
        } catch {
            failed = "Couldn't save the reel. \(error.localizedDescription)"
        }
    }
}
