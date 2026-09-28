import PhotoEngineCore
import SwiftUI

struct LibraryWorkspace: View {
    @ObservedObject var model: PhotoEngineViewModel

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: model.cellSize, maximum: model.cellSize + 48), spacing: 6)]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if model.visibleRows.isEmpty {
                ContentUnavailableView {
                    Label("Nothing in \(model.filter.title.lowercased())", systemImage: model.filter.symbol)
                } description: {
                    Text("Try another set in the sidebar, or run again with a gentler cull.")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: 6) {
                            ForEach(model.visibleRows) { row in
                                PhotoGridCell(model: model, row: row, mark: model.mark(for: row.id), isFocused: model.focusedID == row.id, isInAlbum: model.isInAlbum(row))
                                    .id(row.id)
                            }
                        }
                        .padding(18)
                    }
                    .onChange(of: model.focusedID) { _, id in
                        guard let id else { return }
                        withAnimation(.easeOut(duration: 0.15)) {
                            proxy.scrollTo(id)
                        }
                    }
                }
            }
        }
        .background(StudioChrome.canvas)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(headline)
                    .font(StudioType.title)
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(StudioChrome.secondary)
            }
            Spacer()
            HStack(spacing: 8) {
                Image(systemName: "square.grid.3x3")
                    .foregroundStyle(StudioChrome.tertiary)
                Slider(value: $model.cellSize, in: 120...260, step: 8)
                    .frame(width: 120)
            }
            if !model.pendingConfirmations.isEmpty {
                Button("Confirm \(model.pendingConfirmations.count)") { model.workspace = .confirm }
                    .buttonStyle(.borderedProminent)
                    .tint(StudioChrome.pick)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }

    private var headline: String {
        if model.result != nil {
            let summary = model.albumSummary
            return "\(summary.kept) kept from \(summary.total)"
        }
        return "\(model.rows.count) photos"
    }

    private var subtitle: String {
        var parts = [model.filter.title]
        if model.result != nil {
            let summary = model.albumSummary
            parts.append("\(summary.unusable) unusable")
            let waiting = summary.pending
            parts.append(waiting == 0 ? "Nothing to confirm" : "\(waiting) to confirm")
        }
        parts.append(model.mode.displayName)
        parts.append(model.aggressiveness.displayName)
        return parts.joined(separator: "  ·  ")
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
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(isFocused ? StudioChrome.focus : Color.clear, lineWidth: 2)
            }
            .contentShape(Rectangle())
            .onTapGesture(count: 2) {
                model.focusedID = row.id
                model.albumMode = .loupe
            }
            .onTapGesture {
                model.focusedID = row.id
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
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(LinearGradient(colors: [.clear, .black.opacity(0.6)], startPoint: .top, endPoint: .bottom))
        }
    }

    private func badge(_ symbol: String, tint: Color) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(tint)
            .frame(width: 20, height: 20)
            .background(.black.opacity(0.55), in: Circle())
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
