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
        .background(StudioChrome.photo)
        .onChange(of: model.currentConfirmation?.id) { _, _ in
            showingRunnersUp = false
            if let id = model.currentConfirmation?.suggestedID {
                model.focusedID = id
            }
            model.loupeZoom = .fit
        }
    }

    private func momentView(_ moment: ConfirmationMoment) -> some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 14) {
                Text(progressTitle)
                    .font(StudioType.caption)
                    .foregroundStyle(StudioChrome.tertiary)
                    .monospacedDigit()
                Text(model.suggestionExplanation(for: moment))
                    .font(StudioType.ui)
                    .foregroundStyle(StudioChrome.secondary)
                    .lineLimit(1)
                Spacer()
                HStack(spacing: 14) {
                    if model.primaryFaceBox(for: moment.suggestedID) != nil || moment.candidateIDs.contains(where: { model.primaryFaceBox(for: $0) != nil }) {
                        Button(model.loupeZoom == .face ? "Full frame" : "Eyes") {
                            model.loupeZoom = model.loupeZoom == .face ? .fit : .face
                        }
                    }
                    Button("Skip") { model.skipConfirmation() }
                        .keyboardShortcut(.cancelAction)
                }
                .buttonStyle(StudioQuietButtonStyle())
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 14)

            StudioHairline()

            Group {
                if moment.isChoice {
                    HStack(spacing: 2) {
                        ForEach(moment.candidateIDs, id: \.self) { id in
                            if let row = model.row(for: id) {
                                candidate(row, moment: moment)
                            }
                        }
                    }
                } else if let row = model.row(for: moment.suggestedID) {
                    confirmPreview(for: row)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(StudioChrome.photo)

            if showingRunnersUp {
                StudioHairline()
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 2) {
                        ForEach(moment.hiddenRunnerUpIDs, id: \.self) { id in
                            if let row = model.row(for: id) {
                                Button { model.focusedID = id } label: {
                                    StudioThumb(
                                        url: row.previewURL ?? row.sourceURL,
                                        width: 120,
                                        height: 80,
                                        maxPixelSize: 320,
                                        isFocused: model.focusedID == id
                                    )
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .padding(.horizontal, 22)
                    .padding(.vertical, 10)
                }
            }

            StudioHairline()
            HStack(spacing: 16) {
                Button(moment.isChoice ? "Keep this one" : "Keep it") {
                    model.acceptSuggestion()
                }
                .buttonStyle(StudioButtonStyle(primary: true))
                .keyboardShortcut(.return, modifiers: [])

                if let focused = model.focusedID,
                   focused != moment.suggestedID,
                   moment.candidateIDs.contains(focused) || moment.hiddenRunnerUpIDs.contains(focused) {
                    Button("Use this photo") { model.useConfirmationCandidate(focused) }
                        .buttonStyle(StudioQuietButtonStyle())
                }
                if !moment.isChoice {
                    Button("Drop it") { model.dropSuggestion() }
                        .buttonStyle(StudioQuietButtonStyle())
                }
                if !moment.hiddenRunnerUpIDs.isEmpty {
                    Button(showingRunnersUp ? "Hide others" : "\(moment.hiddenRunnerUpIDs.count) others") {
                        withAnimation(StudioChrome.ease) { showingRunnersUp.toggle() }
                    }
                    .buttonStyle(StudioQuietButtonStyle())
                }
                Spacer()
                if model.pendingConfirmations.contains(where: \.isChoice) {
                    Button("Decide the rest for me") { model.acceptRemainingChoices() }
                        .buttonStyle(StudioQuietButtonStyle())
                }
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 14)
            .background(StudioChrome.canvas)
        }
    }

    private func candidate(_ row: CuratedRow, moment: ConfirmationMoment) -> some View {
        let suggested = row.id == moment.suggestedID
        let focused = model.focusedID == row.id
        return Button {
            model.focusedID = row.id
        } label: {
            ZStack(alignment: .topLeading) {
                StudioChrome.photo
                confirmPreview(for: row)
                if suggested {
                    Text("Suggestion")
                        .font(StudioType.caption)
                        .foregroundStyle(StudioChrome.text)
                        .shadow(color: .black.opacity(0.85), radius: 3, y: 1)
                        .padding(12)
                }
            }
            .overlay {
                Rectangle()
                    .strokeBorder(focused ? StudioChrome.focus : Color.clear, lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .help(row.sourceURL.lastPathComponent)
    }

    private func confirmPreview(for row: CuratedRow) -> some View {
        ConfirmLoupe(url: row.previewURL ?? row.sourceURL, zoom: model.loupeZoom, face: model.primaryFaceBox(for: row.id))
    }

    private var finished: some View {
        VStack(spacing: 18) {
            Text("That's every close call.")
                .font(StudioType.display)
            Text(model.albumSummary.sentence)
                .font(StudioType.ui)
                .foregroundStyle(StudioChrome.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 400)
            if model.confirmationsBeyondCap > 0 {
                Text("The other \(model.confirmationsBeyondCap) were clear enough to decide automatically.")
                    .font(StudioType.caption)
                    .foregroundStyle(StudioChrome.tertiary)
            }
            HStack(spacing: 18) {
                Button("Choose a style") { model.workspace = .look }
                    .buttonStyle(StudioButtonStyle(primary: true))
                Button("See the album") {
                    model.workspace = .album
                    model.albumMode = .grid
                }
                .buttonStyle(StudioQuietButtonStyle())
            }
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(StudioChrome.canvas)
    }

    private var progressTitle: String {
        let done = model.confirmations.count - model.pendingConfirmations.count + 1
        return "\(min(done, model.confirmations.count)) / \(model.confirmations.count)"
    }
}

private struct ConfirmLoupe: View {
    let url: URL
    let zoom: LoupeZoom
    var face: CGRectCodable?

    @State private var image: NSImage?

    var body: some View {
        ZStack {
            StudioChrome.photo
            if let image {
                ZoomableLoupe(image: image, zoom: zoom, face: face)
                    .transition(.opacity)
            }
        }
        .animation(StudioChrome.ease, value: image != nil)
        .task(id: url.path) {
            if let warm = ThumbnailCache.shared.cachedImage(url: url, maxPixelSize: 1600) {
                image = warm
            }
            image = await ThumbnailCache.shared.image(url: url, maxPixelSize: 1600)
        }
    }
}
