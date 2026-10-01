import EventKit
import SwiftUI

/// The optional "what was this?" step before finishing. Everything here is
/// optional; the book is written from the photos either way. Calendar access is
/// asked only if the person taps the button.
struct TripContextPicker: View {
    let trip: TripSummary
    @Binding var note: String
    @Binding var events: [String]
    @State private var suggestions: [String] = []
    @State private var calendarDenied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("What was this trip? (optional)")
                .font(.subheadline.weight(.semibold)).foregroundStyle(Color.ink)
            TextField("Sam's birthday weekend in Lisbon", text: $note, axis: .vertical)
                .lineLimit(1...3)
                .padding(12)
                .background(Color.ink.opacity(0.05), in: .rect(cornerRadius: 12))
            if suggestions.isEmpty {
                Button {
                    Task { await loadCalendar() }
                } label: {
                    Label(calendarDenied ? "Calendar access is off" : "Suggest from my calendar", systemImage: "calendar")
                        .font(.footnote)
                }
                .disabled(calendarDenied)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack {
                        ForEach(suggestions, id: \.self) { title in
                            let picked = events.contains(title)
                            Button {
                                if picked { events.removeAll { $0 == title } } else { events.append(title) }
                            } label: {
                                Label(title, systemImage: picked ? "checkmark" : "calendar")
                                    .font(.footnote)
                                    .padding(.horizontal, 12).padding(.vertical, 7)
                                    .background(picked ? Color.accentColor.opacity(0.18) : Color.ink.opacity(0.05), in: .capsule)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            Text("Only what you add here and what's in the photos goes into the diary.")
                .font(.caption).foregroundStyle(Color.ink.opacity(0.5))
        }
    }

    private func loadCalendar() async {
        let store = EKEventStore()
        guard (try? await store.requestFullAccessToEvents()) == true else {
            calendarDenied = true
            return
        }
        let predicate = store.predicateForEvents(withStart: trip.start.addingTimeInterval(-86_400), end: trip.end.addingTimeInterval(86_400), calendars: nil)
        let titles = store.events(matching: predicate)
            .filter { !$0.isAllDay || $0.endDate.timeIntervalSince($0.startDate) > 86_400 }
            .compactMap(\.title)
            .filter { !$0.isEmpty }
        suggestions = Array(NSOrderedSet(array: titles).compactMap { $0 as? String }.prefix(6))
        if suggestions.isEmpty { calendarDenied = true }
    }
}
