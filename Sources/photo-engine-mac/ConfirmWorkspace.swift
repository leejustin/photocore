import PhotoEngineCore
import SwiftUI

struct ConfirmationMoment: Identifiable, Equatable {
    let id: String
    let suggestedID: PhotoID
    let candidateIDs: [PhotoID]
    let reason: String
    let margin: Double
    var hiddenRunnerUpIDs: [PhotoID] = []

    var isChoice: Bool { candidateIDs.count > 1 }
}

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
            summaryStrip
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(progressTitle)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(StudioChrome.pick)
                    Text(moment.isChoice ? "Which frame should we keep?" : "Keep this one?")
                        .font(StudioType.display)
                    Text(model.suggestionExplanation(for: moment))
                        .font(.body)
                        .foregroundStyle(StudioChrome.secondary)
                }
                Spacer()
                HStack(spacing: 8) {
                    Button(model.loupeZoom == .face ? "Full frame" : "Check eyes") {
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
                    .background(Color.black, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
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
                Button(moment.isChoice ? "Keep the suggestion" : "Keep it") {
                    model.acceptSuggestion()
                }
                .buttonStyle(.borderedProminent)
                .tint(StudioChrome.pick)
                .keyboardShortcut(.return, modifiers: [])
                if let focused = model.focusedID, focused != moment.suggestedID, moment.candidateIDs.contains(focused) || moment.hiddenRunnerUpIDs.contains(focused) {
                    Button("Use this frame") { model.useConfirmationCandidate(focused) }
                }
                if !moment.isChoice {
                    Button("Drop it") { model.dropSuggestion() }
                }
                if !moment.hiddenRunnerUpIDs.isEmpty {
                    Button(showingRunnersUp ? "Hide other frames" : "Show \(moment.hiddenRunnerUpIDs.count) other frames") {
                        showingRunnersUp.toggle()
                    }
                }
                Spacer()
                Text("Return keeps the suggestion · P keeps the selected frame · X drops · Esc skips · E checks eyes")
                    .font(.caption)
                    .foregroundStyle(StudioChrome.tertiary)
            }
        }
        .padding(22)
    }

    private var summaryStrip: some View {
        let summary = model.albumSummary
        return HStack(spacing: 16) {
            summaryChip("\(summary.total)", "in")
            summaryChip("\(summary.kept)", "kept")
            summaryChip("\(summary.unusable)", "unusable")
            summaryChip("\(summary.pending)", "for you")
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(StudioChrome.elevated, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func summaryChip(_ value: String, _ label: String) -> some View {
        HStack(spacing: 4) {
            Text(value).font(.caption.weight(.semibold).monospacedDigit())
            Text(label).font(.caption).foregroundStyle(StudioChrome.tertiary)
        }
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
                            .font(.caption2.weight(.bold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(StudioChrome.pick, in: Capsule())
                            .foregroundStyle(.black)
                            .padding(10)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(focused ? StudioChrome.focus : Color.clear, lineWidth: 2)
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
            Text("Nothing else needs you.")
                .font(StudioType.display)
            Text(model.albumSummary.sentence)
                .foregroundStyle(StudioChrome.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 440)
            if model.confirmationsBeyondCap > 0 {
                Text("We showed you the 16 closest calls. \(model.confirmationsBeyondCap) more were clear enough to decide automatically.")
                    .font(.caption)
                    .foregroundStyle(StudioChrome.tertiary)
            }
            HStack(spacing: 10) {
                Button("Choose the look") { model.workspace = .look }
                    .buttonStyle(.borderedProminent)
                    .tint(StudioChrome.pick)
                Button("Browse the album") {
                    model.workspace = .album
                    model.albumMode = .grid
                }
            }
        }
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
