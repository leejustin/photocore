import PhotoEngineCore
import PhotoEngineWorkflow
import SwiftUI

struct ConfirmWorkspace: View {
    @ObservedObject var model: PhotoEngineViewModel
    @State private var showingRunnersUp = false

    var body: some View {
        Group {
            if let moment = model.currentConfirmation {
                momentView(moment)
            } else {
                finished
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(StudioChrome.canvas)
        .onChange(of: model.currentConfirmation?.id) { _, _ in
            showingRunnersUp = false
            if let id = model.currentConfirmation?.suggestedID {
                model.focusedID = id
            }
            model.loupeZoom = .fit
        }
    }

    private func momentView(_ moment: ConfirmationMoment) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text(progressTitle)
                    .font(.system(size: 12))
                    .foregroundStyle(StudioChrome.tertiary)
                Text(model.suggestionExplanation(for: moment))
                    .font(.system(size: 12))
                    .foregroundStyle(StudioChrome.secondary)
                    .lineLimit(1)
                Spacer()
                HStack(spacing: 8) {
                    Button(model.loupeZoom == .face ? "Full photo" : "Zoom to a face") {
                        model.loupeZoom = model.loupeZoom == .face ? .fit : .face
                    }
                    Button("Skip") { model.skipConfirmation() }
                        .keyboardShortcut(.cancelAction)
                }
            }

            if moment.isChoice {
                HStack(alignment: .top, spacing: 12) {
                    ForEach(moment.candidateIDs, id: \.self) { id in
                        if let row = model.row(for: id) {
                            candidate(row, moment: moment)
                        }
                    }
                }
                .frame(maxHeight: .infinity)
            } else if let row = model.row(for: moment.suggestedID) {
                confirmPreview(for: row)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.black)
            }

            if showingRunnersUp {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(moment.hiddenRunnerUpIDs, id: \.self) { id in
                            if let row = model.row(for: id) {
                                Button { model.focusedID = id } label: {
                                    CachedThumbnail(url: row.sourceURL, maxPixelSize: 320)
                                        .frame(width: 132, height: 88)
                                        .background(Color.black)
                                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                                        .overlay {
                                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                                .strokeBorder(model.focusedID == id ? Color.white : Color.clear, lineWidth: 2)
                                        }
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
                .frame(height: 92)
            }

            HStack(spacing: 10) {
                Button(moment.isChoice ? "Keep this one" : "Keep it") {
                    model.acceptSuggestion()
                }
                .buttonStyle(StudioButtonStyle(primary: true))
                .keyboardShortcut(.return, modifiers: [])
                if let focused = model.focusedID, focused != moment.suggestedID, moment.candidateIDs.contains(focused) || moment.hiddenRunnerUpIDs.contains(focused) {
                    Button("Use this photo") { model.useConfirmationCandidate(focused) }
                }
                if !moment.isChoice {
                    Button("Drop it") { model.dropSuggestion() }
                }
                if !moment.hiddenRunnerUpIDs.isEmpty {
                    Button(showingRunnersUp ? "Hide other photos" : "Show \(moment.hiddenRunnerUpIDs.count) other photos") {
                        showingRunnersUp.toggle()
                    }
                }
                Spacer()
                if model.pendingConfirmations.contains(where: \.isChoice) {
                    Button("Let Photocore pick the duplicates") { model.acceptRemainingChoices() }
                }
            }
        }
        .padding(22)
        .buttonStyle(StudioQuietButtonStyle())
    }

    private func candidate(_ row: CuratedRow, moment: ConfirmationMoment) -> some View {
        let suggested = row.id == moment.suggestedID
        let focused = model.focusedID == row.id
        return Button {
            model.focusedID = row.id
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                ZStack(alignment: .topLeading) {
                    Color.black
                    confirmPreview(for: row)
                    if suggested {
                        Text("Suggestion")
                            .font(.system(size: 11))
                            .foregroundStyle(StudioChrome.text)
                            .shadow(color: .black.opacity(0.8), radius: 3, y: 1)
                            .padding(10)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 2, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .strokeBorder(focused ? StudioChrome.focus : Color.white.opacity(0.08), lineWidth: 1)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.sourceURL.lastPathComponent)
                        .font(.caption)
                        .foregroundStyle(StudioChrome.secondary)
                        .lineLimit(1)
                    if let reason = row.reasons.first {
                        Text(reason)
                            .font(.caption2)
                            .foregroundStyle(StudioChrome.tertiary)
                            .lineLimit(1)
                    }
                }
            }
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func confirmPreview(for row: CuratedRow) -> some View {
        ConfirmLoupe(url: row.sourceURL, zoom: model.loupeZoom, face: model.primaryFaceBox(for: row.id))
    }

    private var finished: some View {
        VStack(spacing: 14) {
            Text("That's every close call.")
                .font(.system(size: 22, weight: .regular))
            Text(model.albumSummary.sentence)
                .foregroundStyle(StudioChrome.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 440)
            if model.confirmationsBeyondCap > 0 {
                Text("The other \(model.confirmationsBeyondCap) were clear enough to decide automatically.")
                    .font(.caption)
                    .foregroundStyle(StudioChrome.tertiary)
            }
            HStack(spacing: 16) {
                Button("Choose a style") { model.workspace = .look }
                    .buttonStyle(StudioButtonStyle(primary: true))
                Button("See the album") {
                    model.workspace = .album
                    model.albumMode = .grid
                }
            }
        }
        .buttonStyle(StudioQuietButtonStyle())
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var progressTitle: String {
        let done = model.confirmations.count - model.pendingConfirmations.count + 1
        return "Moment \(min(done, model.confirmations.count)) of \(model.confirmations.count)"
    }
}

private struct ConfirmLoupe: View {
    let url: URL
    let zoom: LoupeZoom
    var face: CGRectCodable?

    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                ZoomableLoupe(image: image, zoom: zoom, face: face)
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .task(id: url.path) {
            image = await ThumbnailCache.shared.image(url: url, maxPixelSize: 1600)
        }
    }
}
