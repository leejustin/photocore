import AppKit
import PhotoEngineApple
import PhotoEngineCore
import SwiftUI

/// Renders `photo` with `recipe` off the main thread. Soft crossfade — no spinner.
struct LookPreviewTile: View {
    let photo: AnalyzedPhoto
    let recipe: EditRecipe
    var maxLongEdge: Int = 640

    @State private var image: NSImage?

    private struct Key: Equatable {
        let photoID: PhotoID
        let recipe: EditRecipe
    }

    var body: some View {
        ZStack {
            StudioChrome.photo
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .transition(.opacity)
            }
        }
        .clipped()
        .animation(StudioChrome.ease, value: image != nil)
        .task(id: Key(photoID: photo.id, recipe: recipe)) {
            try? await Task.sleep(for: .milliseconds(80))
            guard !Task.isCancelled else { return }
            let photo = photo
            let recipe = recipe
            let maxLongEdge = maxLongEdge
            let data = await Task.detached(priority: .userInitiated) {
                try? ApplePhotoRenderer().previewJPEG(photo: photo, recipe: recipe, maxLongEdge: maxLongEdge, quality: 0.8)
            }.value
            guard !Task.isCancelled, let data, let rendered = NSImage(data: data) else { return }
            image = rendered
        }
    }
}
