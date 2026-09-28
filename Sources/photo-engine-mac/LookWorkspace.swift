import AppKit
import PhotoEngineApple
import PhotoEngineCore
import SwiftUI
import UniformTypeIdentifiers

struct LookWorkspace: View {
    @ObservedObject var model: PhotoEngineViewModel
    @State private var importingLUT = false
    @State private var importingXMP = false

    private var samples: [AnalyzedPhoto] { model.lookSamplePhotos }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Choose a look")
                    .font(StudioType.display)
                Text("Previews update as you choose. Sources are never modified.")
                    .foregroundStyle(StudioChrome.secondary)
            }
            lookStrip
            controls
            if samples.isEmpty {
                ContentUnavailableView("No keepers yet", systemImage: "photo.on.rectangle", description: Text("Confirm the close calls, then choose a look."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 12)], spacing: 12) {
                        ForEach(samples) { photo in
                            LookPreviewTile(photo: photo, recipe: model.baseRecipe(for: photo))
                                .aspectRatio(3 / 2, contentMode: .fit)
                                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        }
                    }
                }
            }
            footer
        }
        .padding(22)
        .background(StudioChrome.canvas)
        .onAppear {
            for photo in samples { model.ensureHorizon(for: photo) }
        }
        .onChange(of: model.autoStraightenLook) { _, _ in
            for photo in samples { model.ensureHorizon(for: photo) }
        }
        .fileImporter(isPresented: $importingLUT, allowedContentTypes: [UTType(filenameExtension: "cube") ?? .data], allowsMultipleSelection: false) { result in
            if case .success(let urls) = result, let url = urls.first {
                model.importLook(from: url, kind: .lut)
            }
        }
        .fileImporter(isPresented: $importingXMP, allowedContentTypes: [UTType(filenameExtension: "xmp") ?? .xml, .data], allowsMultipleSelection: false) { result in
            if case .success(let urls) = result, let url = urls.first {
                model.importLook(from: url, kind: .xmp)
            }
        }
    }

    private var lookStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(model.availableLooks) { look in
                    let selected = model.selectedLookID == look.id
                    Button {
                        model.selectedLookID = look.id
                        if let style = look.style { model.style = style }
                    } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            if let first = samples.first {
                                LookPreviewTile(photo: first, recipe: model.recipe(for: first, look: look), maxLongEdge: 220)
                                    .frame(width: 104, height: 70)
                                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                            }
                            Text(look.name)
                                .font(.caption.weight(.medium))
                                .lineLimit(1)
                            Text(look.kind == .builtin ? "Built-in" : look.kind.rawValue.uppercased())
                                .font(.caption2)
                                .foregroundStyle(StudioChrome.tertiary)
                        }
                        .frame(width: 104, alignment: .leading)
                        .padding(6)
                        .background(selected ? StudioChrome.pick.opacity(0.14) : Color.clear, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .strokeBorder(selected ? StudioChrome.pick : StudioChrome.hairline, lineWidth: selected ? 2 : 1)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 2)
        }
    }

    private var controls: some View {
        HStack(spacing: 14) {
            Toggle("Auto straighten", isOn: $model.autoStraightenLook)
                .toggleStyle(.checkbox)
            HStack(spacing: 6) {
                Text("Warmth")
                    .font(.caption)
                    .foregroundStyle(StudioChrome.secondary)
                Slider(value: $model.lookTemperature, in: -0.6...0.6, step: 0.05)
                    .frame(width: 140)
                Text(String(format: "%+.0f", model.lookTemperature * 100))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(StudioChrome.tertiary)
                    .frame(width: 32, alignment: .trailing)
            }
            Spacer()
            Button("Import LUT…") { importingLUT = true }
            Button("Import XMP…") { importingXMP = true }
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            if let progress = model.lookRenderProgress {
                ProgressView(value: Double(progress.done), total: Double(max(progress.total, 1)))
                    .tint(StudioChrome.pick)
                    .frame(width: 160)
                Text("Rendering \(progress.done) of \(progress.total)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(StudioChrome.secondary)
            }
            Spacer()
            Button(model.lookIsApplied ? "Continue to Deliver" : "Use this look") {
                if model.lookIsApplied {
                    model.workspace = .deliver
                } else {
                    model.applyAlbumLook()
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(StudioChrome.pick)
            .controlSize(.large)
            .disabled(model.isReexportingLook || samples.isEmpty)
        }
    }
}
