import AppKit
import PhotoEngineApple
import PhotoEngineCore
import SwiftUI
import UniformTypeIdentifiers

struct LookWorkspace: View {
    @ObservedObject var model: PhotoEngineViewModel
    @State private var importingLUT = false
    @State private var importingXMP = false
    @State private var showMore = false

    private var samples: [AnalyzedPhoto] { model.lookSamplePhotos }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Your original photos stay untouched.")
                .font(.system(size: 12))
                .foregroundStyle(StudioChrome.secondary)
            lookStrip
            controls
            if samples.isEmpty {
                Text("Check the close calls, then choose a style.")
                    .font(.system(size: 13))
                    .foregroundStyle(StudioChrome.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 12)], spacing: 12) {
                        ForEach(samples) { photo in
                            LookPreviewTile(photo: photo, recipe: model.baseRecipe(for: photo))
                                .aspectRatio(3 / 2, contentMode: .fit)
                                .clipShape(RoundedRectangle(cornerRadius: 2, style: .continuous))
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
                                    .clipShape(RoundedRectangle(cornerRadius: 2, style: .continuous))
                            }
                            Text(look.name)
                                .font(.caption.weight(.medium))
                                .lineLimit(1)
                            if look.kind != .builtin {
                                Text("Imported")
                                    .font(.caption2)
                                    .foregroundStyle(StudioChrome.tertiary)
                            }
                        }
                        .frame(width: 104, alignment: .leading)
                        .padding(6)
                        .background(selected ? Color.white.opacity(0.04) : Color.clear, in: RoundedRectangle(cornerRadius: 2, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 2, style: .continuous)
                                .strokeBorder(selected ? StudioChrome.text.opacity(0.7) : StudioChrome.hairline, lineWidth: 1)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 2)
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 14) {
                Toggle("Straighten tilted photos", isOn: $model.autoStraightenLook)
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
                Button(showMore ? "Hide options" : "More options") { showMore.toggle() }
            }
            if showMore {
                HStack(spacing: 14) {
                    if model.lookSamplePhotos.contains(where: { $0.asset.metadata.format.isRawMaster && PhotoFormatSupport.companionJPEG(for: $0.asset.url) != nil }) {
                        Picker("Start from", selection: $model.renderBase) {
                            Text("Original file").tag(RenderBase.raw)
                            Text("Camera photo").tag(RenderBase.cameraJPEG)
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 220)
                    }
                    Button("Import a color file…") { importingLUT = true }
                    Button("Import a Lightroom preset…") { importingXMP = true }
                    Spacer()
                }
            }
        }
        .buttonStyle(StudioQuietButtonStyle())
    }

    private var footer: some View {
        HStack(spacing: 12) {
            if let progress = model.lookRenderProgress {
                ProgressView(value: Double(progress.done), total: Double(max(progress.total, 1)))
                    .frame(width: 160)
                Text("Updating \(progress.done) of \(progress.total)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(StudioChrome.secondary)
            }
            Spacer()
            Button(model.lookIsApplied ? "Continue to Save" : "Use this style") {
                if model.lookIsApplied {
                    model.workspace = .deliver
                } else {
                    model.applyAlbumLook()
                }
            }
            .buttonStyle(StudioButtonStyle(primary: true))
            .disabled(model.isReexportingLook || samples.isEmpty)
        }
    }
}
