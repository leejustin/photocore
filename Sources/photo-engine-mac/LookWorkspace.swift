import AppKit
import PhotoEngineApple
import PhotoEngineCore
import SwiftUI
import UniformTypeIdentifiers

struct LookWorkspace: View {
    @ObservedObject var model: PhotoEngineViewModel
    @State private var importingLUT = false
    @State private var importingXMP = false
    @State private var importingStyleRefs = false
    @State private var showMore = false

    private var samples: [AnalyzedPhoto] { model.lookSamplePhotos }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("Your originals stay untouched.")
                    .font(StudioType.ui)
                    .foregroundStyle(StudioChrome.secondary)
                Spacer()
                Button(showMore ? "Less" : "Import / options") {
                    withAnimation(StudioChrome.ease) { showMore.toggle() }
                }
                .buttonStyle(StudioQuietButtonStyle())
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 14)

            lookStrip
                .padding(.bottom, 8)

            if showMore {
                moreOptions
                    .padding(.horizontal, 22)
                    .padding(.bottom, 12)
                    .transition(.opacity)
            }

            StudioHairline()

            Group {
                if samples.isEmpty {
                    StudioEmptyCopy(
                        title: "No keepers yet",
                        detail: "Check the close calls, then choose a style."
                    )
                } else {
                    ScrollView {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 240), spacing: 2)], spacing: 2) {
                            ForEach(samples) { photo in
                                LookPreviewTile(photo: photo, recipe: model.baseRecipe(for: photo))
                                    .aspectRatio(3 / 2, contentMode: .fit)
                            }
                        }
                        .padding(2)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(StudioChrome.photo)

            StudioHairline()
            footer
        }
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
        .fileImporter(isPresented: $importingStyleRefs, allowedContentTypes: [.jpeg, .heic, .png, .image], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result {
                model.matchStyleFromReferences(urls)
            }
        }
    }

    private var lookStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 14) {
                ForEach(model.availableLooks) { look in
                    let selected = model.selectedLookID == look.id
                    Button {
                        model.selectedLookID = look.id
                        if let style = look.style { model.style = style }
                    } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            if let first = samples.first {
                                LookPreviewTile(photo: first, recipe: model.recipe(for: first, look: look), maxLongEdge: 220)
                                    .frame(width: 108, height: 72)
                                    .clipped()
                                    .overlay {
                                        Rectangle()
                                            .strokeBorder(selected ? StudioChrome.focus : StudioChrome.hairline, lineWidth: selected ? 1 : 0.5)
                                    }
                            } else {
                                Rectangle()
                                    .fill(StudioChrome.elevated)
                                    .frame(width: 108, height: 72)
                            }
                            Text(look.name)
                                .font(selected ? StudioType.uiMedium : StudioType.caption)
                                .foregroundStyle(selected ? StudioChrome.text : StudioChrome.secondary)
                                .lineLimit(1)
                        }
                        .frame(width: 108, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 4)
        }
    }

    private var moreOptions: some View {
        HStack(spacing: 18) {
            Toggle("Straighten tilted photos", isOn: $model.autoStraightenLook)
                .toggleStyle(.checkbox)
                .font(StudioType.caption)
            HStack(spacing: 8) {
                Text("Warmth")
                    .font(StudioType.caption)
                    .foregroundStyle(StudioChrome.secondary)
                Slider(value: $model.lookTemperature, in: -0.6...0.6, step: 0.05)
                    .frame(width: 120)
                Text(String(format: "%+.0f", model.lookTemperature * 100))
                    .font(StudioType.caption.monospacedDigit())
                    .foregroundStyle(StudioChrome.tertiary)
                    .frame(width: 28, alignment: .trailing)
            }
            if model.lookSamplePhotos.contains(where: { $0.asset.metadata.format.isRawMaster && PhotoFormatSupport.companionJPEG(for: $0.asset.url) != nil }) {
                Picker("Start from", selection: $model.renderBase) {
                    Text("Original").tag(RenderBase.raw)
                    Text("Camera JPEG").tag(RenderBase.cameraJPEG)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 200)
            }
            Spacer()
            Button("Match my style…") { importingStyleRefs = true }
            Button("Balance album") { model.applyAlbumConsistency() }
            Button("Import LUT…") { importingLUT = true }
            Button("Import XMP…") { importingXMP = true }
        }
        .buttonStyle(StudioQuietButtonStyle())
    }

    private var footer: some View {
        HStack(spacing: 14) {
            if !showMore {
                Toggle("Straighten", isOn: $model.autoStraightenLook)
                    .toggleStyle(.checkbox)
                    .font(StudioType.caption)
            }
            Toggle("Retouch", isOn: $model.albumRetouchEnabled)
                .toggleStyle(.checkbox)
                .font(StudioType.caption)
            if let progress = model.lookRenderProgress {
                ProgressView(value: Double(progress.done), total: Double(max(progress.total, 1)))
                    .tint(StudioChrome.text)
                    .frame(width: 140)
                Text("\(progress.done) of \(progress.total)")
                    .font(StudioType.caption.monospacedDigit())
                    .foregroundStyle(StudioChrome.tertiary)
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
        .padding(.horizontal, 22)
        .padding(.vertical, 14)
        .background(StudioChrome.canvas)
    }
}
