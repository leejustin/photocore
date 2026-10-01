import Foundation

/// A run of photos close enough in time to read as one trip or event.
public struct DetectedTrip: Sendable, Equatable, Identifiable {
    public var start: Date
    public var end: Date
    public var photoCount: Int
    /// Index into the caller's date array of a representative photo (the middle one).
    public var coverIndex: Int

    public var id: String { "\(Int(start.timeIntervalSince1970))-\(Int(end.timeIntervalSince1970))" }
    public var days: Int {
        let calendar = Calendar.current
        let span = calendar.dateComponents([.day], from: calendar.startOfDay(for: start), to: calendar.startOfDay(for: end)).day ?? 0
        return span + 1
    }
}

/// Finds trips and events in a camera roll from capture dates alone, so the app
/// can open on "your recent trips" instead of a date picker.
public enum TripDetector {
    /// - Parameters:
    ///   - dates: capture dates, any order.
    ///   - gap: a pause longer than this starts a new trip. A night's sleep is
    ///     under it; going home for a few days is over it.
    ///   - minimumPhotos: shorter runs are everyday life, not a trip.
    ///   - maximumDays: longer runs are split at their largest internal pause.
    /// - Returns: trips, most recent first.
    public static func detect(
        dates: [Date],
        gap: TimeInterval = 20 * 3600,
        minimumPhotos: Int = 20,
        maximumDays: Int = 21
    ) -> [DetectedTrip] {
        let order = dates.indices.sorted { dates[$0] < dates[$1] }
        guard !order.isEmpty else { return [] }
        var runs: [[Int]] = []
        var current: [Int] = [order[0]]
        for index in order.dropFirst() {
            if let last = current.last, dates[index].timeIntervalSince(dates[last]) > gap {
                runs.append(current)
                current = [index]
            } else {
                current.append(index)
            }
        }
        runs.append(current)
        let split = runs.flatMap { splitLong($0, dates: dates, maximumDays: maximumDays) }
        return split
            .filter { $0.count >= minimumPhotos }
            .map { run in
                DetectedTrip(start: dates[run[0]], end: dates[run[run.count - 1]], photoCount: run.count, coverIndex: run[run.count / 2])
            }
            .sorted { $0.start > $1.start }
    }

    private static func splitLong(_ run: [Int], dates: [Date], maximumDays: Int) -> [[Int]] {
        guard run.count > 1,
              dates[run[run.count - 1]].timeIntervalSince(dates[run[0]]) > Double(maximumDays) * 86_400 else { return [run] }
        var largest = 1
        var largestGap = -1.0
        for position in 1..<run.count {
            let pause = dates[run[position]].timeIntervalSince(dates[run[position - 1]])
            if pause > largestGap {
                largestGap = pause
                largest = position
            }
        }
        return splitLong(Array(run[..<largest]), dates: dates, maximumDays: maximumDays)
            + splitLong(Array(run[largest...]), dates: dates, maximumDays: maximumDays)
    }
}
