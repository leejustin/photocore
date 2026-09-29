import PhotoEngineCore
import PhotoEngineWorkflow
import SwiftUI

struct LibraryWorkspace: View {
    @ObservedObject var model: PhotoEngineViewModel

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: model.cellSize, maximum: model.cellSize + 48), spacing: 2)]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 14) {
                Text("Spray")
                    .font(StudioType.caption)
                    .foregroundStyle(StudioChrome.tertiary)
                sprayButton("Off", flag: nil)
                sprayButton("Pick", flag: .pick)
                sprayButton("Hide", flag: .reject)
                if model.tasteProfile.isReady {
                    Text("Taste on")
                        .font(StudioType.caption)
                        .foregroundStyle(StudioChrome.tertiary)
                }
                Spacer()
                Button("Cull report") { model.exportCullReport() }
                    .buttonStyle(StudioQuietButtonStyle())
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            StudioHairline()

            if model.visibleRows.isEmpty {
                Text("Nothing in \(model.filter.title.lowercased()).")
                    .font(StudioType.ui)
                    .foregroundStyle(StudioChrome.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: 1) {
                            ForEach(model.visibleRows) { row in
                                PhotoGridCell(model: model, row: row, mark: model.mark(for: row.id), isFocused: model.focusedID == row.id, isInAlbum: model.isInAlbum(row))
                                    .id(row.id)
                            }
                        }
                        .padding(1)
                    }
                    .onChange(of: model.focusedID) { _, id in
                        guard let id else { return }
                        withAnimation(StudioChrome.ease) {
                            proxy.scrollTo(id)
                        }
                        prewarmAround(id)
                    }
                    .onAppear { prewarmAround(model.focusedID) }
                    .onChange(of: model.filter) { _, _ in
                        prewarmAround(model.visibleRows.first?.id)
                    }
                }
            }
        }
        .background(StudioChrome.photo)
    }

    private func sprayButton(_ title: String, flag: ReviewFlag?) -> some View {
        let active = model.sprayMode == flag
        return Button(title) { model.sprayMode = flag }
            .buttonStyle(.plain)
            .font(active ? StudioType.uiMedium : StudioType.caption)
            .foregroundStyle(active ? StudioChrome.text : StudioChrome.tertiary)
    }

    private func prewarmAround(_ id: PhotoID?) {
        let rows = model.visibleRows
        guard !rows.isEmpty else { return }
        let index = id.flatMap { focused in rows.firstIndex(where: { $0.id == focused }) } ?? 0
        let start = max(0, index - 12)
        let end = min(rows.count, index + 36)
        let urls = rows[start..<end].map { $0.previewURL ?? $0.sourceURL }
        ThumbnailCache.shared.prewarm(urls: urls, maxPixelSize: 480)
        // Loupe-sized warm for the focused and next few.
        let loupeEnd = min(rows.count, index + 6)
        let loupeURLs = rows[index..<loupeEnd].map { $0.previewURL ?? $0.sourceURL }
        ThumbnailCache.shared.prewarm(urls: loupeURLs, maxPixelSize: 1600)
    }
}

private struct PhotoGridCell: View {
    let model: PhotoEngineViewModel
    let row: CuratedRow
    let mark: PhotoReviewMark
    let isFocused: Bool
    let isInAlbum: Bool

    private var isDimmed: Bool { row.bucket == .hidden || mark.flag == .reject }

    var body: some View {
        Color.black
            .overlay {
                CachedThumbnail(url: row.previewURL ?? row.sourceURL, maxPixelSize: 480, contentMode: .fill)
                    .saturation(isDimmed ? 0 : 1)
                    .opacity(isDimmed ? 0.45 : 1)
            }
            .overlay(alignment: .topLeading) { bucketBadge.padding(6) }
            .overlay(alignment: .topTrailing) { flagBadge.padding(6) }
            .overlay(alignment: .bottom) { marksBar }
            .aspectRatio(1, contentMode: .fit)
            .clipShape(Rectangle())
            .overlay {
                Rectangle()
                    .strokeBorder(StudioChrome.focus, lineWidth: isFocused ? 1 : 0)
                    .animation(StudioChrome.ease, value: isFocused)
            }
            .contentShape(Rectangle())
            .onTapGesture(count: 2) {
                model.focusedID = row.id
                model.albumMode = .loupe
            }
            .onTapGesture {
                model.focusedID = row.id
                if model.sprayMode != nil {
                    model.spray(row.id)
                }
            }
            .help(row.sourceURL.lastPathComponent)
            .contextMenu { contextMenuItems }
            .accessibilityLabel("\(row.sourceURL.lastPathComponent), \(row.bucket.displayName)")
    }

    @ViewBuilder
    private var bucketBadge: some View {
        switch row.bucket {
        case .protected: badge("lock.fill", tint: StudioChrome.text)
        case .alternate: badge("rectangle.on.rectangle", tint: StudioChrome.secondary)
        case .review: badge("questionmark", tint: StudioChrome.text)
        case .selected, .hidden: EmptyView()
        }
    }

    @ViewBuilder
    private var flagBadge: some View {
        switch mark.flag {
        case .pick: badge("flag.fill", tint: StudioChrome.pick)
        case .reject: badge("xmark", tint: StudioChrome.reject)
        case .unflagged: EmptyView()
        }
    }

    @ViewBuilder
    private var marksBar: some View {
        if mark.stars > 0 || mark.color != .none {
            HStack(spacing: 4) {
                if mark.stars > 0 {
                    Text(String(repeating: "★", count: mark.stars))
                        .font(.caption2)
                        .foregroundStyle(StudioChrome.pick)
                }
                Spacer()
                if mark.color != .none {
                    Circle().fill(mark.color.swatch).frame(width: 8, height: 8)
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
        }
    }

    private func badge(_ symbol: String, tint: Color) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(tint)
            .shadow(color: .black.opacity(0.85), radius: 2, y: 1)
    }

    @ViewBuilder
    private var contextMenuItems: some View {
        Button("Open") { model.focusedID = row.id; model.albumMode = .loupe }
        Divider()
        Button("Pick") { model.updateMark(row.id) { $0.flag = .pick } }
        Button("Reject") { model.updateMark(row.id) { $0.flag = .reject } }
        Button("Protect") { model.override(photoID: row.id, bucket: .protected) }
        if !isInAlbum {
            Button("Restore to album") { model.restoreToAlbum(row.id) }
        }
        Button("Adjust…") {
            model.focusedID = row.id
            model.openAdjust()
        }
        Menu("Stars") {
            ForEach(0...5, id: \.self) { stars in
                Button(stars == 0 ? "Clear" : String(repeating: "★", count: stars)) {
                    model.updateMark(row.id) { $0.stars = stars }
                }
            }
        }
    }
}
