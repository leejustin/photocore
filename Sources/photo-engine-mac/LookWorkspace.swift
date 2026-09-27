import PhotoEngineCore
import SwiftUI

struct LookWorkspace: View {
    @ObservedObject var model: PhotoEngineViewModel

    private var samples: [CuratedRow] {
        Array(model.rows.filter { $0.bucket == .selected || $0.bucket == .protected }.prefix(9))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("One look for the album")
                        .font(.system(size: 28, weight: .semibold, design: .serif))
                    Text("Pick a direction. Photocore re-renders the keepers with that look. Sources stay untouched.")
                        .foregroundStyle(StudioChrome.secondary)
                }
                Spacer()
                if model.isReexportingLook {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            HStack(spacing: 8) {
                ForEach(StylePreset.allCases, id: \.self) { preset in
                    Button {
                        model.style = preset
                    } label: {
                        Text(preset.displayName)
                            .font(.subheadline.weight(.medium))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(model.style == preset ? StudioChrome.pick : StudioChrome.elevated, in: Capsule())
                            .foregroundStyle(model.style == preset ? .black : StudioChrome.text)
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
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
                Text("Current look: \(model.style.displayName)")
                    .font(.caption)
                    .foregroundStyle(StudioChrome.tertiary)
                Spacer()
                Button("Back to album") { model.workspace = .album }
            }
        }
        .padding(22)
        .background(StudioChrome.canvas)
    }
}
