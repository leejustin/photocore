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
            StudioHairline(axis: .vertical)
            controls
                .frame(width: 260)
                .background(StudioChrome.canvas)
        }
        .background(StudioChrome.photo)
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
            HStack(spacing: 14) {
                Text(model.focusedRow?.sourceURL.lastPathComponent ?? "Select a photo")
                    .font(StudioType.ui)
                    .foregroundStyle(StudioChrome.secondary)
                    .lineLimit(1)
                Spacer()
                Button(model.showingOriginal ? "Show edit" : "Original") {
                    model.showingOriginal.toggle()
                }
                .keyboardShortcut("\\", modifiers: [])
                Button("Done") { model.workspace = model.workspaceBeforeAdjust }
                    .keyboardShortcut(.cancelAction)
            }
            .buttonStyle(StudioQuietButtonStyle())
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .background(StudioChrome.canvas)

            StudioHairline()

            ZStack {
                StudioChrome.photo
                if let preview {
                    Image(nsImage: preview)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .padding(16)
                        .transition(.opacity)
                } else if model.focusedRow == nil {
                    Text("Pick a keeper in the album, then open Adjust.")
                        .font(StudioType.ui)
                        .foregroundStyle(StudioChrome.secondary)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .animation(StudioChrome.ease, value: preview != nil)

            StudioHairline()
            filmstrip
        }
    }

    private var filmstrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                ForEach(model.rows.filter { $0.bucket == .selected || $0.bucket == .protected || model.mark(for: $0.id).flag == .pick }.prefix(40)) { row in
                    Button {
                        model.focusedID = row.id
                    } label: {
                        StudioThumb(
                            url: row.previewURL ?? row.sourceURL,
                            width: 56,
                            height: 56,
                            maxPixelSize: 160,
                            isFocused: model.focusedID == row.id
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .background(StudioChrome.photo)
    }

    private var controls: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                StudioSectionHeader(title: "Basic")

                slider("Exposure", \.exposure, range: -1.2...1.2)
                slider("Contrast", \.contrast, range: -0.8...0.8)
                slider("Highlights", \.highlights, range: -1...1)
                slider("Shadows", \.shadows, range: -1...1)
                slider("Temp", \.temperature, range: -1...1)
                slider("Tint", \.tint, range: -1...1)
                slider("Saturation", \.saturation, range: -1...1)
                slider("Clarity", \.clarity, range: -0.8...0.8)
                slider("Sharpen", \.sharpening, range: 0...0.8)
                slider("Straighten", \.straighten, range: -15...15, degrees: true)

                StudioHairline()
                    .padding(.vertical, 4)

                HStack(spacing: 16) {
                    Button("Reset") { model.resetDevelopRecipe() }
                        .buttonStyle(StudioQuietButtonStyle())
                    Spacer()
                    Button("Save a copy") { model.renderFocusedEdit() }
                        .buttonStyle(StudioButtonStyle(primary: true))
                        .disabled(model.focusedRow == nil)
                }

                Text("Saves a copy. The original stays untouched.")
                    .font(StudioType.caption)
                    .foregroundStyle(StudioChrome.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(16)
        }
        .scrollIndicators(.hidden)
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

    private func slider(_ title: String, _ keyPath: WritableKeyPath<EditRecipe, Double>, range: ClosedRange<Double>, degrees: Bool = false) -> some View {
        let value = binding(keyPath)
        let scale = max(abs(range.lowerBound), abs(range.upperBound))
        let label = degrees
            ? String(format: "%+.1f°", value.wrappedValue)
            : String(format: "%+d", Int((value.wrappedValue / scale * 100).rounded()))
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                    .font(StudioType.caption)
                    .foregroundStyle(StudioChrome.secondary)
                Spacer()
                Text(label)
                    .font(StudioType.caption.monospacedDigit())
                    .foregroundStyle(StudioChrome.tertiary)
            }
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { model.resetDevelopValue(keyPath) }
            .help("Double-click to reset")
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
            try? await Task.sleep(for: .milliseconds(70))
            let isCurrent = await MainActor.run { token == previewToken }
            guard isCurrent else { return }
            let data = try? ApplePhotoRenderer().previewJPEG(photo: photo, recipe: recipe, maxLongEdge: 1600)
            let image = data.flatMap { NSImage(data: $0) }
            await MainActor.run {
                guard token == previewToken else { return }
                preview = image
            }
        }
    }
}
