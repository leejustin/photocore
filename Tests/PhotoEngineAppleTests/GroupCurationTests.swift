import Foundation
import PhotoEngineCore
import PhotoEngineWorkflow
import Testing

/// The group book's rules: owner keepers stay, the best shot of a shared moment
/// wins, a similar scene hours later is not a repeat, and the budget is shared.
struct GroupCurationTests {
    let start = Date(timeIntervalSince1970: 1_728_460_800)

    func candidate(_ who: String?, score: Double, minutes: Double) -> GroupCuration.Candidate {
        GroupCuration.Candidate(id: PhotoID(), contributor: who, score: score, captureDate: start.addingTimeInterval(minutes * 60))
    }

    /// Photos in the same "scene" group look alike; different groups don't.
    func distance(_ scenes: [PhotoID: Int]) -> (PhotoID, PhotoID) -> Double? {
        { a, b in
            guard let x = scenes[a], let y = scenes[b] else { return nil }
            return x == y ? 0.1 : 0.9
        }
    }

    @Test func bestShotOfASharedMomentWins() {
        let sam = candidate("Sam", score: 0.6, minutes: 0)
        let priya = candidate("Priya", score: 0.8, minutes: 2)
        let leo = candidate("Leo", score: 0.7, minutes: 30)
        let outcome = GroupCuration.curate(owner: [], contributors: [sam, priya, leo], distance: distance([sam.id: 1, priya.id: 1, leo.id: 1]))
        #expect(outcome.kept == [priya.id])
        #expect(outcome.repeats == [sam.id: priya.id, leo.id: priya.id])
    }

    @Test func ownerKeepersAlwaysWinTheirMoment() {
        let owner = candidate(nil, score: 0, minutes: 0)
        let sam = candidate("Sam", score: 0.99, minutes: 1)
        let outcome = GroupCuration.curate(owner: [owner], contributors: [sam], distance: distance([owner.id: 1, sam.id: 1]))
        #expect(outcome.kept.isEmpty)
        #expect(outcome.repeats[sam.id] == owner.id)
    }

    @Test func aSimilarSceneHoursLaterIsANewMoment() {
        let morning = candidate("Sam", score: 0.8, minutes: 0)
        let evening = candidate("Priya", score: 0.7, minutes: 8 * 60)
        let outcome = GroupCuration.curate(owner: [], contributors: [morning, evening], distance: distance([morning.id: 1, evening.id: 1]))
        #expect(Set(outcome.kept) == [morning.id, evening.id])
        #expect(outcome.repeats.isEmpty)
    }

    @Test func budgetIsSharedRoundRobin() {
        // Sam sends ten great, different photos; Priya sends two weaker ones.
        var scenes: [PhotoID: Int] = [:]
        let sam = (0..<10).map { i in candidate("Sam", score: 0.9 - Double(i) * 0.01, minutes: Double(i) * 60) }
        let priya = (0..<2).map { i in candidate("Priya", score: 0.3, minutes: Double(i) * 60 + 30) }
        for (i, photo) in (sam + priya).enumerated() { scenes[photo.id] = i }
        let outcome = GroupCuration.curate(owner: [], contributors: sam + priya, distance: distance(scenes), budget: 6)
        #expect(outcome.kept.count == 6)
        #expect(outcome.keptPerContributor == ["Sam": 4, "Priya": 2])
        // Sam's best four, by score.
        #expect(Set(outcome.kept).isSuperset(of: sam.prefix(4).map(\.id)))
        #expect(outcome.overBudget.count == 6)
    }

    @Test func budgetGrowsWithThePeopleOnTheTrip() {
        #expect(GroupCuration.budget(ownerCount: 0, contributorCount: 2) == 36)
        #expect(GroupCuration.budget(ownerCount: 80, contributorCount: 2) == 80)
        #expect(GroupCuration.budget(ownerCount: 10, contributorCount: 10) == 80)
        #expect(GroupCuration.budget(ownerCount: 500, contributorCount: 50) == 200)
    }

    @Test func booksCreditPhotographersOnlyWhenThereIsMoreThanOne() {
        let a = BookPhoto(id: PhotoID(), fileName: "a.jpg")
        let b = BookPhoto(id: PhotoID(), fileName: "b.jpg")
        let c = BookPhoto(id: PhotoID(), fileName: "c.jpg")
        var book = TripBook(title: "Lisbon", intro: "", dateRange: "", coverPhotoID: nil, sections: [
            BookSection(id: "s1", heading: "", dateLine: "", place: nil, diary: "", photos: [a, b, c])
        ], writer: "template", theme: .book)

        var solo = book
        solo.credit([a.id: "Ana", b.id: "Ana", c.id: "Ana"])
        #expect(solo.creditLine == nil)
        #expect(!BookRenderer.html(solo).contains("class=\"credit\""))

        book.credit([a.id: "Ana", b.id: "Sam", c.id: "Sam"])
        #expect(book.contributors == ["Sam", "Ana"])
        #expect(book.creditLine == "Photos by Sam and Ana")
        let html = BookRenderer.html(book)
        #expect(html.contains("Photos by Sam and Ana"))
        #expect(html.contains("class=\"credit\">Sam<"))

        // The owner gave no name: only the friend is credited, and the line says "with".
        var unnamedOwner = TripBook(title: "Lisbon", intro: "", dateRange: "", coverPhotoID: nil, sections: [
            BookSection(id: "s1", heading: "", dateLine: "", place: nil, diary: "", photos: [a, b, c])
        ], writer: "template", theme: .snapshot)
        unnamedOwner.credit([c.id: "Sam"])
        #expect(unnamedOwner.creditLine == "With photos by Sam")
    }

    @Test func bookLinksToTheInviteOnlyWhenOpen() {
        let book = TripBook(title: "Lisbon", intro: "", dateRange: "", coverPhotoID: nil, sections: [
            BookSection(id: "s1", heading: "", dateLine: "", place: nil, diary: "", photos: [BookPhoto(id: PhotoID(), fileName: "a.jpg")])
        ], writer: "template", theme: .book)
        let open = BookRenderer.html(book, options: .init(guestEndpoint: "/b/x/guest", invitePath: "/j/abc"))
        #expect(open.contains("href=\"/j/abc\""))
        let closed = BookRenderer.html(book, options: .init(guestEndpoint: "/b/x/guest"))
        #expect(!closed.contains("/j/"))
        #expect(!closed.contains("Were you there too?"))
    }

    @Test func oldThemeNamesStillRead() throws {
        let decoded = try JSONDecoder().decode([BookTheme].self, from: Data("[\"scrapbook\", \"snapshot\", \"book\"]".utf8))
        #expect(decoded == [.snapshot, .snapshot, .book])
        #expect(BookTheme(name: "scrapbook") == .snapshot)
        #expect(BookTheme.snapshot.displayName == "Snapshots")
    }
}
