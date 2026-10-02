import Foundation
import PhotoEngineCore

/// Picks one book's worth of photos from everyone who was on the trip.
///
/// Each person's uploads are culled on their own first, so a careful shooter and
/// a burst-happy one both arrive as their own best frames. Then:
/// 1. The owner's keepers are always kept: the owner chose them on the phone.
/// 2. When several people shot the same moment, the best frame wins and the rest
///    are dropped as repeats. Same moment means visually close and, when both
///    photos have a time, taken within `sameMomentWindow` of each other.
/// 3. Contributors share a budget round-robin, each person's best first, so one
///    prolific friend cannot crowd everyone else out of the book.
public enum GroupCuration {
    public struct Candidate: Sendable, Equatable {
        public var id: PhotoID
        /// Who took it; nil for the owner.
        public var contributor: String?
        /// The cull's score; higher is better. Only compared within a moment.
        public var score: Double
        public var captureDate: Date?

        public init(id: PhotoID, contributor: String?, score: Double, captureDate: Date?) {
            self.id = id
            self.contributor = contributor
            self.score = score
            self.captureDate = captureDate
        }
    }

    public struct Outcome: Sendable, Equatable {
        /// Contributor photos that made the book, in the order they were chosen.
        public var kept: [PhotoID]
        /// Contributor photos dropped as repeats, and the photo that won the moment.
        public var repeats: [PhotoID: PhotoID]
        /// Contributor photos that were good and new but over the shared budget.
        public var overBudget: [PhotoID]
        /// Kept photos per contributor.
        public var keptPerContributor: [String: Int]
    }

    public static let duplicateDistance = 0.35
    public static let sameMomentWindow: TimeInterval = 45 * 60

    /// How many contributor photos a book takes: at least 36, room for eight per
    /// person, never fewer than the owner's own keepers, and at most 200.
    public static func budget(ownerCount: Int, contributorCount: Int) -> Int {
        min(200, max(36, ownerCount, 8 * contributorCount))
    }

    public static func curate(
        owner: [Candidate],
        contributors: [Candidate],
        distance: (PhotoID, PhotoID) -> Double?,
        budget: Int? = nil,
        duplicateDistance: Double = duplicateDistance,
        sameMomentWindow: TimeInterval = sameMomentWindow
    ) -> Outcome {
        func sameMoment(_ a: Candidate, _ b: Candidate) -> Bool {
            if let x = a.captureDate, let y = b.captureDate, abs(x.timeIntervalSince(y)) > sameMomentWindow { return false }
            guard let d = distance(a.id, b.id) else { return false }
            return d < duplicateDistance
        }

        // Best frame first; ties go to the earlier photo so runs are repeatable.
        let ordered = contributors.sorted {
            if $0.score != $1.score { return $0.score > $1.score }
            return ($0.captureDate ?? .distantPast, $0.id.description) < ($1.captureDate ?? .distantPast, $1.id.description)
        }
        var winners: [Candidate] = []
        var repeats: [PhotoID: PhotoID] = [:]
        for candidate in ordered {
            if let match = owner.first(where: { sameMoment(candidate, $0) }) ?? winners.first(where: { sameMoment(candidate, $0) }) {
                repeats[candidate.id] = match.id
            } else {
                winners.append(candidate)
            }
        }

        // Round-robin by each person's rank: everyone's best, then everyone's second best.
        var queues: [String: [Candidate]] = [:]
        var people: [String] = []
        for winner in winners {
            let person = winner.contributor ?? ""
            if queues[person] == nil { people.append(person) }
            queues[person, default: []].append(winner)
        }
        let limit = budget ?? self.budget(ownerCount: owner.count, contributorCount: people.count)
        var kept: [PhotoID] = []
        var perPerson: [String: Int] = [:]
        var round = 0
        while kept.count < limit {
            var added = false
            for person in people {
                guard let queue = queues[person], round < queue.count, kept.count < limit else { continue }
                kept.append(queue[round].id)
                perPerson[person, default: 0] += 1
                added = true
            }
            if !added { break }
            round += 1
        }
        let keptSet = Set(kept)
        return Outcome(
            kept: kept,
            repeats: repeats,
            overBudget: winners.map(\.id).filter { !keptSet.contains($0) },
            keptPerContributor: perPerson
        )
    }
}
