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
                Text("Your edit replaces the album look for this photo when you deliver.")
                    .font(.caption)
                    .foregroundStyle(StudioChrome.tertiary)
                Button(model.showingOriginal ? "Show edit" : "Show original") {
                    model.showingOriginal.toggle()
                }
                .keyboardShortcut("\\", modifiers: [])
                Button("Done") { model.workspace = model.workspaceBeforeAdjust }
                    .keyboardShortcut(.cancelAction)
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
                                    .strokeBorder(model.focusedID == row.id ? StudioChrome.focus : Color.clear, lineWidth: 2)
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

    private func slider(_ title: String, _ keyPath: WritableKeyPath<EditRecipe, Double>, range: ClosedRange<Double>, degrees: Bool = false) -> some View {
        let value = binding(keyPath)
        let scale = max(abs(range.lowerBound), abs(range.upperBound))
        let label = degrees
            ? String(format: "%+.1f°", value.wrappedValue)
            : String(format: "%+d", Int((value.wrappedValue / scale * 100).rounded()))
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(StudioChrome.secondary)
                Spacer()
                Text(label)
                    .font(.caption.monospacedDigit())
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
