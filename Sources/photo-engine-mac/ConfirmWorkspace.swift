import PhotoEngineCore
import SwiftUI

struct ConfirmationMoment: Identifiable, Equatable {
    let id: String
    let suggestedID: PhotoID
    let candidateIDs: [PhotoID]
    let reason: String
    let margin: Double

    var isChoice: Bool { candidateIDs.count > 1 }
}

struct ConfirmWorkspace: View {
    @ObservedObject var model: PhotoEngineViewModel

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
            if let id = model.currentConfirmation?.suggestedID {
                model.focusedID = id
            }
        }
    }

    private func momentView(_ moment: ConfirmationMoment) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(progressTitle)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(StudioChrome.pick)
                    Text(moment.isChoice ? "Which frame should we keep?" : "Keep this one?")
                        .font(.system(size: 28, weight: .semibold, design: .serif))
                    Text(moment.reason)
                        .font(.body)
                        .foregroundStyle(StudioChrome.secondary)
                }
                Spacer()
                Button("Skip") { model.skipConfirmation() }
                    .keyboardShortcut(.cancelAction)
            }

            if moment.isChoice {
                HStack(alignment: .top, spacing: 12) {
                    ForEach(moment.candidateIDs, id: \.self) { id in
                        if let row = model.rows.first(where: { $0.id == id }) {
                            candidate(row, moment: moment)
                        }
                    }
                }
                .frame(maxHeight: .infinity)
            } else if let row = model.rows.first(where: { $0.id == moment.suggestedID }) {
                CachedThumbnail(url: row.sourceURL, maxPixelSize: 1600)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.black, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }

            HStack(spacing: 10) {
                Button(moment.isChoice ? "Keep the suggestion" : "Keep it") {
                    model.acceptSuggestion()
                }
                .buttonStyle(.borderedProminent)
                .tint(StudioChrome.pick)
                .keyboardShortcut(.return, modifiers: [])
                if moment.isChoice, let focused = model.focusedID, focused != moment.suggestedID, moment.candidateIDs.contains(focused) {
                    Button("Use this frame") { model.useConfirmationCandidate(focused) }
                }
                if !moment.isChoice {
                    Button("Drop it") { model.dropSuggestion() }
                }
                Spacer()
                Text("Return keeps the suggestion. Arrows move between frames.")
                    .font(.caption)
                    .foregroundStyle(StudioChrome.tertiary)
            }
        }
        .padding(22)
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
                    CachedThumbnail(url: row.sourceURL, maxPixelSize: 1200)
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
                        .strokeBorder(focused ? StudioChrome.pick : Color.clear, lineWidth: 2)
                }
                Text(row.sourceURL.lastPathComponent)
                    .font(.caption)
                    .foregroundStyle(StudioChrome.secondary)
                    .lineLimit(1)
            }
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var finished: some View {
        VStack(spacing: 14) {
            Text("Nothing else needs you.")
                .font(.system(size: 34, weight: .semibold, design: .serif))
            Text("The other frames were decided automatically. The album is the keepers.")
                .foregroundStyle(StudioChrome.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            Button("See the album") { model.workspace = .album }
                .buttonStyle(.borderedProminent)
                .tint(StudioChrome.pick)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var progressTitle: String {
        let done = model.confirmations.count - model.pendingConfirmations.count + 1
        return "Moment \(min(done, model.confirmations.count)) of \(model.confirmations.count)"
    }
}
