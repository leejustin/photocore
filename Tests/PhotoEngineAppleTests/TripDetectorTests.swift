import Foundation
import PhotoEngineCore
import Testing

@Suite("Trip detection")
struct TripDetectorTests {
    let day0 = Date(timeIntervalSince1970: 1_780_000_000)

    func burst(day: Double, count: Int, everyMinutes: Double = 10) -> [Date] {
        (0..<count).map { day0.addingTimeInterval(day * 86_400 + Double($0) * everyMinutes * 60) }
    }

    @Test("a three-day trip with nights in between is one trip")
    func multiDayTrip() {
        let dates = burst(day: 0, count: 30) + burst(day: 1, count: 30) + burst(day: 2, count: 30)
        let trips = TripDetector.detect(dates: dates)
        #expect(trips.count == 1)
        #expect(trips.first?.photoCount == 90)
        #expect(trips.first?.days == 3)
    }

    @Test("everyday handfuls are not trips, and trips sort newest first")
    func everydayIgnored() {
        let dates = burst(day: 0, count: 25) + burst(day: 5, count: 4) + burst(day: 9, count: 3) + burst(day: 20, count: 40)
        let trips = TripDetector.detect(dates: dates.shuffled())
        #expect(trips.map(\.photoCount) == [40, 25])
    }

    @Test("a month of daily photos splits into shorter trips")
    func longRunsSplit() {
        var dates: [Date] = []
        for day in 0..<40 { dates += burst(day: Double(day), count: 3, everyMinutes: 60 * 5) }
        let trips = TripDetector.detect(dates: dates, minimumPhotos: 3)
        #expect(trips.count >= 2)
        #expect(trips.allSatisfy { $0.days <= 21 })
        #expect(trips.reduce(0) { $0 + $1.photoCount } == 120)
    }

    @Test("empty roll has no trips")
    func empty() {
        #expect(TripDetector.detect(dates: []).isEmpty)
    }
}
