import AppKit
import PhotoEngineCore
import PhotoEngineWorkflow
import SwiftUI

struct CullWorkspace: View {
    @ObservedObject var model: PhotoEngineViewModel
    @State private var showEdited = false
    @State private var loupeImage: NSImage?

    private var loupeURL: URL? {
        guard let row = model.focusedRow else { return nil }
        if showEdited, let preview = row.previewURL { return preview }
        return row.sourceURL
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                if model.surveying, let row = model.focusedRow, let group = model.groupsByPhoto[row.id] {
                    survey(group)
                } else {
                    stage
                    if let row = model.focusedRow, let group = model.groupsByPhoto[row.id], group.memberIDs.count > 1 {
                        StudioHairline()
                        similarStrip(group)
                    }
                }
                StudioHairline()
                filmstrip
            }
            StudioHairline(axis: .vertical)
            inspector
                .frame(width: 260)
                .background(StudioChrome.canvas)
        }
        .background(StudioChrome.photo)
        .task(id: "\(loupeURL?.path ?? "")|\(model.loupeZoom == .fit ? 1600 : 4096)|\(showEdited)") {
            guard let loupeURL else {
                loupeImage = nil
                return
            }
            let limit = model.loupeZoom == .fit ? 1600 : 4096
            if let warm = ThumbnailCache.shared.cachedImage(url: loupeURL, maxPixelSize: limit) {
                loupeImage = warm
            }
            loupeImage = await ThumbnailCache.shared.image(url: loupeURL, maxPixelSize: limit)
        }
    }

    private var stage: some View {
        ZStack {
            StudioChrome.photo
            if let loupeImage {
                ZoomableLoupe(
                    image: loupeImage,
                    zoom: model.loupeZoom,
                    face: model.focusedRow.flatMap { model.primaryFaceBox(for: $0.id) }
                )
                .padding(model.loupeZoom == .fit ? 24 : 0)
                .transition(.opacity)
                .onTapGesture(count: 2) { model.cycleLoupeZoom() }
            } else if model.focusedRow == nil {
                Text("No photo in this set")
                    .font(StudioType.ui)
                    .foregroundStyle(StudioChrome.secondary)
            }

            VStack {
                HStack(spacing: 12) {
                    Button("Grid") {
                        model.albumMode = .grid
                        model.surveying = false
                    }
                    .keyboardShortcut(.cancelAction)
                    if let row = model.focusedRow, let index = model.visibleRows.firstIndex(where: { $0.id == row.id }) {
                        Text("\(index + 1) / \(model.visibleRows.count)")
                            .font(StudioType.caption.monospacedDigit())
                            .foregroundStyle(StudioChrome.tertiary)
                    }
                    Spacer()
                    if model.focusedRow.flatMap({ model.groupsByPhoto[$0.id] }) != nil {
                        Button("Survey") { model.toggleSurvey() }
                    }
                    if model.focusedRow.flatMap({ model.primaryFaceBox(for: $0.id) }) != nil {
                        Button("Eyes") { model.zoomToEyes() }
                    }
                    Button(model.loupeZoom == .fit ? "100%" : "Fit") { model.cycleLoupeZoom() }
                    if model.focusedRow?.previewURL != nil {
                        Button(showEdited ? "Edited" : "Original") { showEdited.toggle() }
                    }
                }
                .buttonStyle(StudioQuietButtonStyle())
                Spacer()
            }
            .padding(14)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(StudioChrome.ease, value: loupeImage != nil)
    }

    private func survey(_ group: PhotoGroup) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text(groupTitle(group))
                    .font(StudioType.uiMedium)
                Spacer()
                Button("Close") { model.surveying = false }
                    .buttonStyle(StudioQuietButtonStyle())
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            StudioHairline()
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 280), spacing: 2)], spacing: 2) {
                    ForEach(group.memberIDs, id: \.self) { id in
                        if let row = model.row(for: id) {
                            SurveyCell(model: model, row: row)
                        }
                    }
                }
                .padding(2)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(StudioChrome.photo)
    }

    private func similarStrip(_ group: PhotoGroup) -> some View {
        HStack(spacing: 12) {
            Text(groupTitle(group))
                .font(StudioType.caption)
                .foregroundStyle(StudioChrome.tertiary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(group.memberIDs, id: \.self) { id in
                        if let row = model.row(for: id) {
                            Button { model.focusedID = id } label: {
                                StudioThumb(
                                    url: row.previewURL ?? row.sourceURL,
                                    width: 72,
                                    height: 54,
                                    maxPixelSize: 240,
                                    isFocused: model.focusedID == id
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(StudioChrome.canvas)
    }

    private var filmstrip: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 2) {
                    ForEach(model.visibleRows) { row in
                        Button { model.focusedID = row.id } label: {
                            StudioThumb(
                                url: row.previewURL ?? row.sourceURL,
                                width: 68,
                                height: 50,
                                maxPixelSize: 200,
                                isFocused: model.focusedID == row.id,
                                isDimmed: model.mark(for: row.id).flag == .reject || row.bucket == .hidden
                            )
                        }
                        .buttonStyle(.plain)
                        .id(row.id)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
            }
            .background(StudioChrome.photo)
            .onChange(of: model.focusedID) { _, id in
                guard let id else { return }
                withAnimation(StudioChrome.ease) {
                    proxy.scrollTo(id, anchor: .center)
                }
            }
        }
        .frame(height: 68)
    }

    private var inspector: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if let row = model.focusedRow {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(row.sourceURL.lastPathComponent)
                            .font(StudioType.uiMedium)
                            .textSelection(.enabled)
                            .lineLimit(2)
                        Text(row.bucket.displayName)
                            .font(StudioType.caption)
                            .foregroundStyle(StudioChrome.secondary)
                    }

                    HStack(spacing: 14) {
                        flagButton("Pick", active: model.mark(for: row.id).flag == .pick, tint: StudioChrome.pick) {
                            model.flagFocused(.pick, advance: true)
                        }
                        flagButton("Reject", active: model.mark(for: row.id).flag == .reject, tint: StudioChrome.reject) {
                            model.flagFocused(.reject, advance: true)
                        }
                    }

                    HStack(spacing: 6) {
                        ForEach(1...5, id: \.self) { stars in
                            Button {
                                model.setStars(model.mark(for: row.id).stars == stars ? 0 : stars)
                            } label: {
                                Image(systemName: model.mark(for: row.id).stars >= stars ? "star.fill" : "star")
                                    .font(.system(size: 12))
                                    .foregroundStyle(StudioChrome.pick.opacity(model.mark(for: row.id).stars >= stars ? 1 : 0.35))
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    HStack(spacing: 8) {
                        ForEach(ReviewColor.allCases.filter { $0 != .none }, id: \.self) { color in
                            Button {
                                let current = model.mark(for: row.id).color
                                model.setColor(current == color ? .none : color)
                            } label: {
                                Circle()
                                    .fill(color.swatch)
                                    .frame(width: 12, height: 12)
                                    .overlay {
                                        Circle().strokeBorder(
                                            model.mark(for: row.id).color == color ? Color.white : Color.clear,
                                            lineWidth: 1.5
                                        )
                                    }
                            }
                            .buttonStyle(.plain)
                            .help(color.lightroomLabel ?? "")
                        }
                    }

                    if !row.reasons.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            StudioSectionHeader(title: "Why")
                            ForEach(row.reasons, id: \.self) { reason in
                                Text(reason)
                                    .font(StudioType.ui)
                                    .foregroundStyle(StudioChrome.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }

                    if let photo = model.analyzedPhoto(id: row.id) {
                        VStack(alignment: .leading, spacing: 10) {
                            StudioSectionHeader(title: "Signals")
                            StudioMeter(title: "Sharpness", value: photo.signals.sharpness)
                            if let subject = photo.signals.subjectSharpness {
                                StudioMeter(title: "Subject", value: subject)
                            }
                            StudioMeter(title: "Exposure", value: photo.signals.exposureQuality)
                            if photo.signals.faceCount > 0 {
                                StudioMeter(title: "Faces", value: photo.signals.faceQuality)
                            }
                            if let aesthetic = photo.signals.aestheticScore {
                                StudioMeter(title: "Aesthetics", value: aesthetic)
                            }
                        }

                        VStack(alignment: .leading, spacing: 4) {
                            StudioSectionHeader(title: "Capture")
                            if let camera = photo.asset.metadata.cameraModel {
                                Text(camera).font(StudioType.caption).foregroundStyle(StudioChrome.secondary)
                            }
                            if let lens = photo.asset.metadata.lensModel {
                                Text(lens).font(StudioType.caption).foregroundStyle(StudioChrome.tertiary)
                            }
                            Text("\(photo.asset.metadata.pixelWidth) × \(photo.asset.metadata.pixelHeight)")
                                .font(StudioType.caption.monospacedDigit())
                                .foregroundStyle(StudioChrome.tertiary)
                            if let date = photo.asset.metadata.captureDate {
                                Text(date.formatted(date: .abbreviated, time: .shortened))
                                    .font(StudioType.caption)
                                    .foregroundStyle(StudioChrome.tertiary)
                            }
                        }
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        StudioSectionHeader(title: "Files")
                        Button("Reveal source") { NSWorkspace.shared.activateFileViewerSelecting([row.sourceURL]) }
                        if let previewURL = row.previewURL {
                            Button("Reveal export") { NSWorkspace.shared.activateFileViewerSelecting([previewURL]) }
                        }
                        Button("Protect") { model.override(photoID: row.id, bucket: .protected) }
                        Button("Adjust…") { model.openAdjust() }
                    }
                    .buttonStyle(StudioQuietButtonStyle())
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.hidden)
    }

    private func flagButton(_ title: String, active: Bool, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(StudioType.ui)
                .foregroundStyle(active ? tint : StudioChrome.secondary)
        }
        .buttonStyle(.plain)
    }

    private func groupTitle(_ group: PhotoGroup) -> String {
        let count = group.memberIDs.count
        switch group.kind {
        case .exactDuplicate: return "\(count) exact copies"
        case .burst: return "\(count) in this burst"
        case .scene: return "\(count) in this scene"
        }
    }
}

private struct SurveyCell: View {
    @ObservedObject var model: PhotoEngineViewModel
    let row: CuratedRow

    private var mark: PhotoReviewMark { model.mark(for: row.id) }

    var body: some View {
        Button {
            model.focusedID = row.id
        } label: {
            ZStack(alignment: .topTrailing) {
                CachedThumbnail(url: row.previewURL ?? row.sourceURL, maxPixelSize: 900, contentMode: .fill)
                if mark.flag == .pick {
                    Image(systemName: "flag.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(StudioChrome.pick)
                        .shadow(color: .black.opacity(0.85), radius: 2, y: 1)
                        .padding(8)
                } else if mark.flag == .reject {
                    Image(systemName: "xmark")
                        .font(.system(size: 10))
                        .foregroundStyle(StudioChrome.reject)
                        .shadow(color: .black.opacity(0.85), radius: 2, y: 1)
                        .padding(8)
                } else if row.bucket == .selected || row.bucket == .protected {
                    Text("Kept")
                        .font(StudioType.caption)
                        .foregroundStyle(StudioChrome.text)
                        .shadow(color: .black.opacity(0.85), radius: 2, y: 1)
                        .padding(8)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
            }
            .aspectRatio(3 / 2, contentMode: .fit)
            .clipped()
            .overlay {
                Rectangle()
                    .strokeBorder(model.focusedID == row.id ? StudioChrome.focus : Color.clear, lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .help(row.sourceURL.lastPathComponent)
    }
}
