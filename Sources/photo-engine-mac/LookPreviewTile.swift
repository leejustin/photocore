import AppKit
import PhotoEngineApple
import PhotoEngineCore
import SwiftUI

/// Renders `photo` with `recipe` off the main thread. Keeps the previous image while re-rendering.
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
        Color.black
            .overlay {
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            .clipped()
            .task(id: Key(photoID: photo.id, recipe: recipe)) {
                try? await Task.sleep(for: .milliseconds(120))
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
