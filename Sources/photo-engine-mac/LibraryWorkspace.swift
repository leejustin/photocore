import PhotoEngineCore
import SwiftUI

struct LibraryWorkspace: View {
    @ObservedObject var model: PhotoEngineViewModel

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: model.cellSize, maximum: model.cellSize + 48), spacing: 10)]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if model.visibleRows.isEmpty {
                ContentUnavailableView {
                    Label("Nothing in \(model.filter.title.lowercased())", systemImage: model.filter.symbol)
                } description: {
                    Text("Switch sets in the sidebar, or run the cull again with a gentler setting.")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 10) {
                        ForEach(model.visibleRows) { row in
                            PhotoGridCell(model: model, row: row)
                        }
                    }
                    .padding(18)
                }
            }
        }
        .background(StudioChrome.canvas)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(headline)
                    .font(.title2.weight(.semibold))
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
            parts.append("\(summary.trash) trash")
            let waiting = summary.pending
            parts.append(waiting == 0 ? "Nothing to confirm" : "\(waiting) to confirm")
        }
        parts.append(model.mode.displayName)
        parts.append(model.aggressiveness.displayName)
        return parts.joined(separator: "  ·  ")
    }
}

private struct PhotoGridCell: View {
    @ObservedObject var model: PhotoEngineViewModel
    let row: CuratedRow

    private var mark: PhotoReviewMark { model.mark(for: row.id) }
    private var isFocused: Bool { model.focusedID == row.id }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .topLeading) {
                StudioChrome.elevated
                CachedThumbnail(url: row.previewURL ?? row.sourceURL, maxPixelSize: 480)
                    .padding(8)
                if row.bucket == .hidden || mark.flag == .reject {
                    Color.black.opacity(0.42)
                }
                VStack {
                    HStack {
                        bucketChip
                        Spacer()
                        if mark.flag == .pick {
                            Image(systemName: "flag.fill")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(StudioChrome.pick)
                        } else if mark.flag == .reject {
                            Image(systemName: "xmark")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(StudioChrome.reject)
                        }
                    }
                    Spacer()
                    HStack {
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
                }
                .padding(8)
            }
            .aspectRatio(1, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(isFocused ? StudioChrome.pick : Color.clear, lineWidth: 2)
            }
            Text(row.sourceURL.lastPathComponent)
                .font(.caption2)
                .foregroundStyle(StudioChrome.secondary)
                .lineLimit(1)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            model.focusedID = row.id
        }
        .contextMenu {
            Button("Pick") { model.updateMark(row.id) { $0.flag = .pick } }
            Button("Reject") { model.updateMark(row.id) { $0.flag = .reject } }
            Button("Protect") { model.override(photoID: row.id, bucket: .protected) }
            if row.bucket == .hidden || row.bucket == .review || row.bucket == .alternate {
                Button("Restore to album") { model.restoreToAlbum(row.id) }
            }
            Menu("Stars") {
                ForEach(0...5, id: \.self) { stars in
                    Button(stars == 0 ? "Clear" : String(repeating: "★", count: stars)) {
                        model.updateMark(row.id) { $0.stars = stars }
                    }
                }
            }
        }
        .accessibilityLabel("\(row.sourceURL.lastPathComponent), \(row.bucket.displayName)")
    }

    @ViewBuilder
    private var bucketChip: some View {
        switch row.bucket {
        case .selected, .protected:
            Text("AI")
                .font(.caption2.weight(.bold))
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(StudioChrome.pick.opacity(0.9), in: Capsule())
                .foregroundStyle(.black)
        case .review:
            Text("?")
                .font(.caption2.weight(.bold))
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(.white.opacity(0.16), in: Capsule())
        case .alternate:
            Text("ALT")
                .font(.system(size: 9, weight: .bold))
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(.white.opacity(0.12), in: Capsule())
        case .hidden:
            EmptyView()
        }
    }
}
