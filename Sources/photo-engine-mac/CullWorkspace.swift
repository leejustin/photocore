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
                        similarStrip(group)
                    }
                }
                filmstrip
            }
            inspector
                .frame(width: 280)
                .background(StudioChrome.canvas)
        }
        .background(Color.black)
        .task(id: "\(loupeURL?.path ?? "")|\(model.loupeZoom == .fit ? 1600 : 4096)|\(showEdited)") {
            guard let loupeURL else {
                loupeImage = nil
                return
            }
            let limit = model.loupeZoom == .fit ? 1600 : 4096
            loupeImage = await ThumbnailCache.shared.image(url: loupeURL, maxPixelSize: limit)
        }
    }

    private var stage: some View {
        ZStack {
            Color.black
            if let loupeImage {
                ZoomableLoupe(
                    image: loupeImage,
                    zoom: model.loupeZoom,
                    face: model.focusedRow.flatMap { model.primaryFaceBox(for: $0.id) }
                )
                .padding(model.loupeZoom == .fit ? 28 : 0)
                .onTapGesture(count: 2) { model.cycleLoupeZoom() }
            } else if model.focusedRow == nil {
                Text("No photo in this set")
                    .foregroundStyle(StudioChrome.secondary)
            } else {
                ProgressView()
            }
            VStack {
                HStack(spacing: 8) {
                    Button {
                        model.albumMode = .grid
                        model.surveying = false
                    } label: {
                        Text("Grid")
                    }
                    .buttonStyle(StudioQuietButtonStyle())
                    .keyboardShortcut(.cancelAction)
                    if let row = model.focusedRow, let index = model.visibleRows.firstIndex(where: { $0.id == row.id }) {
                        Text("\(index + 1) of \(model.visibleRows.count)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(StudioChrome.secondary)
                    }
                    Spacer()
                    if model.focusedRow.flatMap({ model.groupsByPhoto[$0.id] }) != nil {
                        Button("Survey") { model.toggleSurvey() }
                            .buttonStyle(StudioQuietButtonStyle())
                    }
                    if model.focusedRow.flatMap({ model.primaryFaceBox(for: $0.id) }) != nil {
                        Button("Eyes") { model.zoomToEyes() }
                            .buttonStyle(StudioQuietButtonStyle())
                    }
                    Button(model.loupeZoom == .fit ? "100%" : "Fit") { model.cycleLoupeZoom() }
                        .buttonStyle(StudioQuietButtonStyle())
                    if model.focusedRow?.previewURL != nil {
                        Button(showEdited ? "Edited" : "Original") { showEdited.toggle() }
                            .buttonStyle(StudioQuietButtonStyle())
                    }
                }
                Spacer()
            }
            .padding(16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func survey(_ group: PhotoGroup) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(groupTitle(group))
                    .font(.headline)
                Spacer()
                Button("Close survey") { model.surveying = false }
                    .buttonStyle(StudioQuietButtonStyle())
            }
            .padding(.horizontal, 18)
            .padding(.top, 14)
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 280), spacing: 12)], spacing: 12) {
                    ForEach(group.memberIDs, id: \.self) { id in
                        if let row = model.row(for: id) {
                            SurveyCell(model: model, row: row)
                        }
                    }
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 12)
            }
            Text("Click a frame, then P to keep it. S closes the survey.")
                .font(.caption)
                .foregroundStyle(StudioChrome.secondary)
                .padding(.horizontal, 18)
                .padding(.bottom, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
    }

    private func similarStrip(_ group: PhotoGroup) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(groupTitle(group))
                .font(.caption.weight(.semibold))
                .foregroundStyle(StudioChrome.secondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(group.memberIDs, id: \.self) { id in
                        if let row = model.row(for: id) {
                            Button {
                                model.focusedID = id
                            } label: {
                                CachedThumbnail(url: row.sourceURL, maxPixelSize: 240)
                                    .frame(width: 86, height: 64)
                                    .background(Color.white.opacity(0.04))
                                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                                    .overlay {
                                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                                            .strokeBorder(model.focusedID == id ? StudioChrome.focus : Color.clear, lineWidth: 2)
                                    }
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
                LazyHStack(spacing: 6) {
                    ForEach(model.visibleRows) { row in
                        Button {
                            model.focusedID = row.id
                        } label: {
                            CachedThumbnail(url: row.sourceURL, maxPixelSize: 200)
                                .frame(width: 72, height: 54)
                                .background(Color.white.opacity(0.04))
                                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                                .overlay {
                                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                                        .strokeBorder(model.focusedID == row.id ? StudioChrome.focus : Color.white.opacity(0.08), lineWidth: model.focusedID == row.id ? 2 : 1)
                                }
                                .opacity(model.mark(for: row.id).flag == .reject || row.bucket == .hidden ? 0.4 : 1)
                        }
                        .buttonStyle(.plain)
                        .id(row.id)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            .background(Color.black)
            .onChange(of: model.focusedID) { _, id in
                guard let id else { return }
                withAnimation(.easeOut(duration: 0.18)) {
                    proxy.scrollTo(id, anchor: .center)
                }
            }
        }
        .frame(height: 74)
    }

    private var inspector: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let row = model.focusedRow {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(row.sourceURL.lastPathComponent)
                            .font(.headline)
                            .textSelection(.enabled)
                        Text(row.bucket.displayName)
                            .font(.subheadline)
                            .foregroundStyle(StudioChrome.secondary)
                    }

                    HStack(spacing: 8) {
                        flagButton("Pick", system: "flag.fill", active: model.mark(for: row.id).flag == .pick, tint: StudioChrome.pick) {
                            model.flagFocused(.pick, advance: true)
                        }
                        flagButton("Reject", system: "xmark", active: model.mark(for: row.id).flag == .reject, tint: StudioChrome.reject) {
                            model.flagFocused(.reject, advance: true)
                        }
                    }

                    HStack(spacing: 4) {
                        ForEach(1...5, id: \.self) { stars in
                            Button {
                                model.setStars(model.mark(for: row.id).stars == stars ? 0 : stars)
                            } label: {
                                Image(systemName: model.mark(for: row.id).stars >= stars ? "star.fill" : "star")
                                    .foregroundStyle(StudioChrome.pick)
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    HStack(spacing: 6) {
                        ForEach(ReviewColor.allCases.filter { $0 != .none }, id: \.self) { color in
                            Button {
                                let current = model.mark(for: row.id).color
                                model.setColor(current == color ? .none : color)
                            } label: {
                                Circle()
                                    .fill(color.swatch)
                                    .frame(width: 16, height: 16)
                                    .overlay {
                                        Circle().strokeBorder(model.mark(for: row.id).color == color ? Color.white : Color.clear, lineWidth: 2)
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
                                    .font(.callout)
                                    .foregroundStyle(StudioChrome.text)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }

                    if let photo = model.analyzedPhoto(id: row.id) {
                        VStack(alignment: .leading, spacing: 8) {
                            StudioSectionHeader(title: "Signals")
                            meter("Sharpness", photo.signals.sharpness)
                            if let subject = photo.signals.subjectSharpness {
                                meter("Subject", subject)
                            }
                            meter("Exposure", photo.signals.exposureQuality)
                            if photo.signals.faceCount > 0 {
                                meter("Faces", photo.signals.faceQuality)
                                Text("\(photo.signals.faceCount) face\(photo.signals.faceCount == 1 ? "" : "s")")
                                    .font(.caption)
                                    .foregroundStyle(StudioChrome.secondary)
                            }
                            if let aesthetic = photo.signals.aestheticScore {
                                meter("Aesthetics", aesthetic)
                            }
                            if !photo.signals.qualityFlags.isEmpty {
                                Text(photo.signals.qualityFlags.joined(separator: " · "))
                                    .font(.caption)
                                    .foregroundStyle(StudioChrome.secondary)
                            }
                        }

                        VStack(alignment: .leading, spacing: 4) {
                            StudioSectionHeader(title: "Capture")
                            if let camera = photo.asset.metadata.cameraModel {
                                Text(camera).font(.callout)
                            }
                            if let lens = photo.asset.metadata.lensModel {
                                Text(lens).font(.caption).foregroundStyle(StudioChrome.secondary)
                            }
                            Text("\(photo.asset.metadata.pixelWidth) × \(photo.asset.metadata.pixelHeight)")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(StudioChrome.secondary)
                            if let date = photo.asset.metadata.captureDate {
                                Text(date.formatted(date: .abbreviated, time: .shortened))
                                    .font(.caption)
                                    .foregroundStyle(StudioChrome.secondary)
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
                    }
                    .buttonStyle(.borderless)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func flagButton(_ title: String, system: String, active: Bool, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
                .foregroundStyle(active ? tint : StudioChrome.secondary)
        }
        .buttonStyle(.plain)
    }

    private func meter(_ title: String, _ value: Double) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                Text("\(Int((min(max(value, 0), 1) * 100).rounded()))")
                    .monospacedDigit()
            }
            .font(.caption)
            .foregroundStyle(StudioChrome.secondary)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Rectangle().fill(Color.white.opacity(0.08))
                    Rectangle()
                        .fill(StudioChrome.text.opacity(0.72))
                        .frame(width: max(0, geo.size.width * CGFloat(min(max(value, 0), 1))))
                }
            }
            .frame(height: 2)
        }
    }

    private func groupTitle(_ group: PhotoGroup) -> String {
        let count = group.memberIDs.count
        switch group.kind {
        case .exactDuplicate: return "\(count) exact copies"
        case .burst: return "\(count) frames in this burst"
        case .scene: return "\(count) frames in this scene"
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
            ZStack(alignment: .bottomLeading) {
                Color.white.opacity(0.04)
                CachedThumbnail(url: row.sourceURL, maxPixelSize: 900)
                LinearGradient(colors: [.clear, .black.opacity(0.72)], startPoint: .center, endPoint: .bottom)
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        if row.bucket == .selected || row.bucket == .protected {
                            Text("Kept")
                                .font(.system(size: 11))
                                .foregroundStyle(StudioChrome.text)
                                .shadow(color: .black.opacity(0.8), radius: 2, y: 1)
                        }
                        Spacer()
                        if mark.flag == .pick {
                            Image(systemName: "flag.fill").foregroundStyle(StudioChrome.pick)
                        } else if mark.flag == .reject {
                            Image(systemName: "xmark").foregroundStyle(StudioChrome.reject)
                        }
                    }
                    Spacer()
                    Text(row.sourceURL.lastPathComponent)
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                    if let reason = row.reasons.first {
                        Text(reason)
                            .font(.caption2)
                            .foregroundStyle(.white.opacity(0.78))
                            .lineLimit(2)
                    }
                }
                .padding(10)
            }
            .aspectRatio(3 / 2, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 2, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .strokeBorder(model.focusedID == row.id ? StudioChrome.focus : Color.white.opacity(0.08), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
    }
}
