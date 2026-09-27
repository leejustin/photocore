import AppKit
import PhotoEngineApple
import PhotoEngineCore
import SwiftUI

/// Optional per-photo develop. Kept quiet on purpose — curation stays the main path.
struct AdjustWorkspace: View {
    @ObservedObject var model: PhotoEngineViewModel
    @State private var preview: NSImage?
    @State private var previewToken = 0

    var body: some View {
        HStack(spacing: 0) {
            previewPane
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Rectangle().fill(StudioChrome.hairline).frame(width: 1)
            controls
                .frame(width: 280)
                .background(StudioChrome.panel)
        }
        .background(StudioChrome.canvas)
        .onAppear {
            model.syncDevelopRecipe()
            refreshPreview()
        }
        .onChange(of: model.focusedID) { _, _ in
            model.syncDevelopRecipe()
            refreshPreview()
        }
        .onChange(of: model.developRecipe) { _, _ in
            refreshPreview()
        }
        .onChange(of: model.showingOriginal) { _, _ in
            refreshPreview()
        }
    }

    private var previewPane: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Adjust")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(StudioChrome.tertiary)
                    Text(model.focusedRow?.sourceURL.lastPathComponent ?? "Select a photo")
                        .font(.headline)
                }
                Spacer()
                Text("Edge-case manual pass. Album Look still covers the shoot.")
                    .font(.caption)
                    .foregroundStyle(StudioChrome.tertiary)
                Button(model.showingOriginal ? "Edited" : "Original") {
                    model.showingOriginal.toggle()
                }
                .keyboardShortcut("\\", modifiers: [])
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)

            ZStack {
                Color.black
                if let preview {
                    Image(nsImage: preview)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .padding(12)
                } else if model.focusedRow != nil {
                    ProgressView().controlSize(.small)
                } else {
                    ContentUnavailableView("Nothing focused", systemImage: "slider.horizontal.3", description: Text("Pick a keeper in the album, then open Adjust."))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            filmstrip
        }
    }

    private var filmstrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(model.rows.filter { $0.bucket == .selected || $0.bucket == .protected || model.mark(for: $0.id).flag == .pick }.prefix(40)) { row in
                    Button {
                        model.focusedID = row.id
                    } label: {
                        CachedThumbnail(url: row.previewURL ?? row.sourceURL, maxPixelSize: 160)
                            .frame(width: 64, height: 64)
                            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                            .overlay {
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .strokeBorder(model.focusedID == row.id ? StudioChrome.pick : Color.clear, lineWidth: 2)
                            }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
        }
        .background(StudioChrome.panel)
    }

    private var controls: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("BASIC")
                    .font(.caption2.weight(.semibold))
                    .tracking(0.8)
                    .foregroundStyle(StudioChrome.tertiary)

                slider("Exposure", value: binding(\.exposure), range: -1.2...1.2)
                slider("Contrast", value: binding(\.contrast), range: -0.8...0.8)
                slider("Highlights", value: binding(\.highlights), range: -1...1)
                slider("Shadows", value: binding(\.shadows), range: -1...1)
                slider("Temp", value: binding(\.temperature), range: -1...1)
                slider("Tint", value: binding(\.tint), range: -1...1)
                slider("Saturation", value: binding(\.saturation), range: -1...1)
                slider("Clarity", value: binding(\.clarity), range: -0.8...0.8)
                slider("Sharpen", value: binding(\.sharpening), range: 0...0.8)
                slider("Straighten", value: binding(\.straighten), range: -15...15)

                Divider().overlay(StudioChrome.hairline)

                HStack(spacing: 8) {
                    Button("Reset") { model.resetDevelopRecipe() }
                    Spacer()
                    Button("Save JPEG") { model.renderFocusedEdit() }
                        .buttonStyle(.borderedProminent)
                        .tint(StudioChrome.pick)
                        .disabled(model.focusedRow == nil)
                }

                Text("Saves into the run’s edits folder. Source files stay untouched.")
                    .font(.caption2)
                    .foregroundStyle(StudioChrome.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(16)
        }
    }

    private func binding(_ keyPath: WritableKeyPath<EditRecipe, Double>) -> Binding<Double> {
        Binding(
            get: { model.developRecipe[keyPath: keyPath] },
            set: { value in
                var recipe = model.developRecipe
                recipe[keyPath: keyPath] = value
                model.setDevelopRecipe(recipe)
            }
        )
    }

    private func slider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(StudioChrome.secondary)
                Spacer()
                Text(String(format: "%.2f", value.wrappedValue))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(StudioChrome.tertiary)
            }
            Slider(value: value, in: range)
        }
    }

    private func refreshPreview() {
        previewToken += 1
        let token = previewToken
        guard let row = model.focusedRow, let photo = model.analyzedPhoto(id: row.id) else {
            preview = nil
            return
        }
        if model.showingOriginal {
            Task {
                let image = await ThumbnailCache.shared.image(url: row.sourceURL, maxPixelSize: 1600)
                await MainActor.run {
                    guard token == previewToken else { return }
                    preview = image
                }
            }
            return
        }
        let recipe = model.developRecipe
        Task.detached(priority: .userInitiated) {
            let data = try? ApplePhotoRenderer().previewJPEG(photo: photo, recipe: recipe, maxLongEdge: 1600)
            let image = data.flatMap { NSImage(data: $0) }
            await MainActor.run {
                guard token == previewToken else { return }
                preview = image
            }
        }
    }
}
