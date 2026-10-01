import PhotoEngineCore
import PhotoEngineWorkflow
import SwiftUI

/// One close call at a time: swipe right to keep the pick, left to drop the moment,
/// or tap an alternative to keep that frame instead.
struct SwipeReviewView: View {
    let run: TripRun
    @Environment(\.dismiss) private var dismiss
    @State private var chosen: PhotoID?
    @State private var drag: CGSize = .zero
    @State private var total = 0

    var body: some View {
        NavigationStack {
            VStack(spacing: 18) {
                if let moment = run.openMoments.first {
                    counter
                    card(for: moment)
                    if moment.isChoice { alternatives(for: moment) }
                    actions(for: moment)
                } else {
                    Spacer()
                    Image(systemName: "checkmark.circle").font(.system(size: 56)).foregroundStyle(Color.accentColor)
                    Text("All close calls done").font(.display(26))
                    Text("\(run.keepers.count) keepers").foregroundStyle(Color.ink.opacity(0.6))
                    Spacer()
                    Button("Done") { dismiss() }.buttonStyle(PrimaryButtonStyle())
                }
            }
            .padding(20)
            .background(Color.paper)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
            }
            .onAppear { total = max(total, run.openMoments.count) }
        }
    }

    private var counter: some View {
        let done = total - run.openMoments.count + 1
        return Text("\(done) of \(total)")
            .font(.footnote.weight(.semibold)).monospacedDigit()
            .foregroundStyle(Color.ink.opacity(0.5))
    }

    private func card(for moment: ConfirmationMoment) -> some View {
        let shown = chosen ?? moment.suggestedID
        return VStack(alignment: .leading, spacing: 12) {
            if let photo = run.photo(shown) {
                FileImage(url: photo.asset.url, maxPixel: 1200, contentMode: .fit)
                    .clipShape(.rect(cornerRadius: 18))
            }
            Text(explanation(moment))
                .font(.subheadline).foregroundStyle(Color.ink.opacity(0.7))
        }
        .offset(x: drag.width)
        .rotationEffect(.degrees(Double(drag.width) / 25))
        .overlay(alignment: .topLeading) { badge(text: "KEEP", color: .green, visible: drag.width > 40) }
        .overlay(alignment: .topTrailing) { badge(text: "DROP", color: .red, visible: drag.width < -40) }
        .gesture(
            DragGesture()
                .onChanged { drag = $0.translation }
                .onEnded { value in
                    if value.translation.width > 120 { decide(chosen.map { .use($0) } ?? .accept, moment) }
                    else if value.translation.width < -120 { decide(.drop, moment) }
                    else { withAnimation(.spring) { drag = .zero } }
                }
        )
        .frame(maxHeight: .infinity)
    }

    private func badge(text: String, color: Color, visible: Bool) -> some View {
        Text(text)
            .font(.headline.weight(.heavy)).tracking(2)
            .padding(.horizontal, 12).padding(.vertical, 6)
            .foregroundStyle(color)
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(color, lineWidth: 3))
            .padding(16)
            .opacity(visible ? 1 : 0)
    }

    private func alternatives(for moment: ConfirmationMoment) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(moment.candidateIDs, id: \.self) { id in
                    if let photo = run.photo(id) {
                        let selected = (chosen ?? moment.suggestedID) == id
                        Button { chosen = id } label: {
                            FileImage(url: photo.asset.url, maxPixel: 300)
                                .frame(width: 72, height: 72)
                                .clipShape(.rect(cornerRadius: 10))
                                .overlay(RoundedRectangle(cornerRadius: 10).stroke(selected ? Color.accentColor : .clear, lineWidth: 3))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .frame(height: 76)
    }

    private func actions(for moment: ConfirmationMoment) -> some View {
        HStack(spacing: 14) {
            Button { decide(.drop, moment) } label: {
                Label("Drop", systemImage: "xmark").frame(maxWidth: .infinity).padding(.vertical, 14)
            }
            .buttonStyle(.bordered).tint(Color.ink)
            Button { decide(chosen.map { .use($0) } ?? .accept, moment) } label: {
                Label("Keep", systemImage: "checkmark").frame(maxWidth: .infinity).padding(.vertical, 14)
            }
            .buttonStyle(.borderedProminent)
        }
        .font(.headline)
    }

    private func explanation(_ moment: ConfirmationMoment) -> String {
        guard let result = run.result else { return moment.reason }
        if moment.isChoice {
            return ConfirmationBuilder.explanation(for: moment, analyzed: result.analyzed)
        }
        return "Keep this one? " + moment.reason.prefix(1).uppercased() + moment.reason.dropFirst() + "."
    }

    private func decide(_ action: ConfirmationAction, _ moment: ConfirmationMoment) {
        withAnimation(.easeOut(duration: 0.2)) {
            drag = .zero
            run.swipe(action, on: moment)
            chosen = nil
        }
    }
}
