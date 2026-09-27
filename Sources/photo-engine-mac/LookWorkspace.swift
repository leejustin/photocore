import AppKit
import PhotoEngineApple
import PhotoEngineCore
import SwiftUI
import UniformTypeIdentifiers

struct LookWorkspace: View {
    @ObservedObject var model: PhotoEngineViewModel
    @State private var importingLUT = false
    @State private var importingXMP = false

    private var samples: [CuratedRow] {
        Array(model.rows.filter { $0.bucket == .selected || $0.bucket == .protected }.prefix(9))
    }

    private var looks: [AlbumLook] { model.availableLooks }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("One look for the album")
                        .font(.system(size: 28, weight: .semibold, design: .serif))
                    Text("Built-in looks, or import a .cube LUT / Lightroom .xmp develop preset. Photocore re-renders keepers; sources stay untouched.")
                        .foregroundStyle(StudioChrome.secondary)
                }
                Spacer()
                if model.isReexportingLook {
                    ProgressView().controlSize(.small)
                }
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(looks) { look in
                        Button {
                            model.selectedLookID = look.id
                            if let style = look.style { model.style = style }
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(look.name)
                                    .font(.subheadline.weight(.medium))
                                Text(look.kind == .builtin ? "Built-in" : look.kind.rawValue.uppercased())
                                    .font(.caption2)
                                    .foregroundStyle(model.selectedLookID == look.id ? .black.opacity(0.7) : StudioChrome.tertiary)
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(model.selectedLookID == look.id ? StudioChrome.pick : StudioChrome.elevated, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .foregroundStyle(model.selectedLookID == look.id ? .black : StudioChrome.text)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            HStack(spacing: 10) {
                Toggle("Auto straighten", isOn: $model.autoStraightenLook)
                    .toggleStyle(.checkbox)
                HStack {
                    Text("Warmth")
                        .font(.caption)
                        .foregroundStyle(StudioChrome.secondary)
                    Slider(value: $model.lookTemperature, in: -0.6...0.6, step: 0.05)
                        .frame(width: 140)
                }
                Spacer()
                Button("Import LUT…") { importingLUT = true }
                Button("Import XMP…") { importingXMP = true }
                Button("Apply look") { model.applyAlbumLook() }
                    .buttonStyle(.borderedProminent)
                    .tint(StudioChrome.pick)
                    .disabled(model.isReexportingLook || samples.isEmpty)
                    .keyboardShortcut(.return, modifiers: [])
            }

            if samples.isEmpty {
                ContentUnavailableView("No keepers yet", systemImage: "photo.on.rectangle", description: Text("Confirm the close calls, then choose a look."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: 12)], spacing: 12) {
                    ForEach(samples) { row in
                        VStack(alignment: .leading, spacing: 6) {
                            CachedThumbnail(url: row.previewURL ?? row.sourceURL, maxPixelSize: 720)
                                .frame(maxWidth: .infinity)
                                .aspectRatio(1, contentMode: .fit)
                                .background(Color.black, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                                .clipped()
                            Text(row.sourceURL.lastPathComponent)
                                .font(.caption2)
                                .foregroundStyle(StudioChrome.secondary)
                                .lineLimit(1)
                        }
                    }
                }
                .frame(maxHeight: .infinity, alignment: .top)
            }

            HStack {
                Text("Current: \(model.selectedLook?.name ?? model.style.displayName)")
                    .font(.caption)
                    .foregroundStyle(StudioChrome.tertiary)
                Spacer()
                Button("Back to album") { model.workspace = .album }
            }
        }
        .padding(22)
        .background(StudioChrome.canvas)
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
}
