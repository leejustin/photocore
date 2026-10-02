import SwiftUI

/// The first screen, before iOS asks for Photos access, so people know what
/// they are agreeing to and why.
struct WelcomeView: View {
    let onContinue: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer(minLength: 40)
            Text("Finish the trip.")
                .font(.display(44)).foregroundStyle(Color.ink)
                .padding(.bottom, 14)
            Text("You took hundreds of photos. Photocore turns them into the handful worth keeping, and a book worth sharing.")
                .font(.title3).foregroundStyle(Color.ink.opacity(0.7))
                .padding(.bottom, 36)
            VStack(alignment: .leading, spacing: 22) {
                point("sparkles", "Picks your best shots", "Finds the keepers in each trip and skips near-duplicates, blinks and blur. It runs on this iPhone.")
                point("lock", "Never deletes anything", "Photos you don't keep stay in your library. Tidying up is your choice, and it's undoable.")
                point("book", "Turns a trip into a book", "When you want, finish a trip into a shared book with a short diary of where you went.")
            }
            Spacer()
            Button("Continue", action: onContinue)
                .buttonStyle(PrimaryButtonStyle())
            Text("Next, iOS asks to let Photocore see your photos.")
                .font(.footnote).foregroundStyle(Color.ink.opacity(0.5))
                .frame(maxWidth: .infinity)
                .padding(.top, 10)
        }
        .padding(.horizontal, 28)
        .padding(.bottom, 20)
        .background(Color.paper)
    }

    private func point(_ symbol: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(Color.accentColor)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline).foregroundStyle(Color.ink)
                Text(detail).font(.subheadline).foregroundStyle(Color.ink.opacity(0.65))
            }
        }
    }
}
