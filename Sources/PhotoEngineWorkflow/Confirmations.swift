import Foundation
import PhotoEngineApple
import PhotoEngineCore

public struct ConfirmationMoment: Identifiable, Equatable, Sendable {
    public let id: String
    public let suggestedID: PhotoID
    public let candidateIDs: [PhotoID]
    public let reason: String
    public let margin: Double
    public var hiddenRunnerUpIDs: [PhotoID]

    public init(id: String, suggestedID: PhotoID, candidateIDs: [PhotoID], reason: String, margin: Double, hiddenRunnerUpIDs: [PhotoID] = []) {
        self.id = id
        self.suggestedID = suggestedID
        self.candidateIDs = candidateIDs
        self.reason = reason
        self.margin = margin
        self.hiddenRunnerUpIDs = hiddenRunnerUpIDs
    }

    public var isChoice: Bool { candidateIDs.count > 1 }
}

public struct MarkChange: Sendable, Equatable {
    public var photoID: PhotoID
    public var flag: ReviewFlag

    public init(photoID: PhotoID, flag: ReviewFlag) {
        self.photoID = photoID
        self.flag = flag
    }
}

public struct BucketOverride: Sendable, Equatable {
    public var photoID: PhotoID
    public var bucket: SelectionBucket

    public init(photoID: PhotoID, bucket: SelectionBucket) {
        self.photoID = photoID
        self.bucket = bucket
    }
}

public enum ConfirmationAction: Sendable, Equatable {
    case accept
    case use(PhotoID)
    case drop
}

public enum ConfirmationBuilder {
    public static func build(result: PipelineResult, rows: [CuratedRow], groups: [PhotoID: PhotoGroup]) -> (moments: [ConfirmationMoment], beyondCap: Int) {
        let rowsByID = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
        func row(for id: PhotoID) -> CuratedRow? { rowsByID[id] }
        let analyzedByID = Dictionary(uniqueKeysWithValues: result.analyzed.map { ($0.id, $0) })

        var moments: [ConfirmationMoment] = []
        var covered = Set<PhotoID>()
        for group in result.grouping.groups where group.kind != .exactDuplicate && group.memberIDs.count > 1 {
            let visible = group.memberIDs.compactMap { row(for: $0) }.filter { $0.bucket != .hidden }
            guard visible.count >= 2 else { continue }
            let ranked = visible.sorted { $0.score > $1.score }
            guard let best = ranked.first, let second = ranked.dropFirst().first else { continue }
            let margin = best.score - second.score
            guard margin < 0.08 else { continue }
            covered.formUnion(ranked.map(\.id))
            let candidates = Array(ranked.prefix(4).map(\.id))
            let candidateSet = Set(candidates)
            let runnersUp = group.memberIDs.filter { id in
                guard !candidateSet.contains(id), let row = row(for: id) else { return false }
                return !row.reasons.contains(where: PhotoTechnicalReject.isTechnicalRejectReason)
            }
            moments.append(ConfirmationMoment(
                id: group.id.uuidString,
                suggestedID: best.id,
                candidateIDs: candidates,
                reason: best.reasons.first ?? "These frames are close.",
                margin: margin,
                hiddenRunnerUpIDs: runnersUp
            ))
        }
        for row in rows where row.bucket == .selected || row.bucket == .protected {
            guard !covered.contains(row.id), groups[row.id] == nil else { continue }
            let flags = analyzedByID[row.id]?.signals.qualityFlags.filter {
                $0 == "subject appears soft" || $0 == "face quality low" || $0 == PhotoTechnicalReject.eyesClosed
            } ?? []
            guard !flags.isEmpty else { continue }
            covered.insert(row.id)
            moments.append(ConfirmationMoment(
                id: row.id.description,
                suggestedID: row.id,
                candidateIDs: [row.id],
                reason: flags.joined(separator: " · "),
                margin: 0
            ))
        }
        for row in rows where row.bucket == .review && !covered.contains(row.id) {
            guard !row.reasons.contains(where: PhotoTechnicalReject.isTechnicalRejectReason) else { continue }
            moments.append(ConfirmationMoment(
                id: row.id.description,
                suggestedID: row.id,
                candidateIDs: [row.id],
                reason: row.reasons.first ?? "Just missed the cut.",
                margin: 0.05
            ))
        }
        let sorted = moments.sorted { $0.margin < $1.margin }
        return (Array(sorted.prefix(16)), max(0, sorted.count - 16))
    }

    public static func explanation(for moment: ConfirmationMoment, analyzed: [AnalyzedPhoto]) -> String {
        let analyzedByID = Dictionary(uniqueKeysWithValues: analyzed.map { ($0.id, $0) })
        guard moment.isChoice, let best = analyzedByID[moment.suggestedID] else { return moment.reason }
        let others = moment.candidateIDs.filter { $0 != moment.suggestedID }.compactMap { analyzedByID[$0] }
        guard !others.isEmpty else { return moment.reason }
        func focus(_ photo: AnalyzedPhoto) -> Double { photo.signals.subjectSharpness ?? photo.signals.sharpness }
        func eyesClosed(_ photo: AnalyzedPhoto) -> Bool { photo.signals.qualityFlags.contains(PhotoTechnicalReject.eyesClosed) }
        var edges: [String] = []
        if others.allSatisfy({ focus(best) - focus($0) > 0.05 }) { edges.append("is sharper") }
        if best.signals.faceCount > 0, others.allSatisfy({ best.signals.faceQuality - $0.signals.faceQuality > 0.05 }) {
            edges.append("has better faces")
        }
        if !eyesClosed(best), others.contains(where: eyesClosed) { edges.append("has open eyes") }
        if others.allSatisfy({ best.signals.exposureQuality - $0.signals.exposureQuality > 0.05 }) {
            edges.append("is better exposed")
        }
        guard !edges.isEmpty else { return "These frames are nearly identical. Either is a fine keep." }
        return "Suggested because it " + ListFormatter.localizedString(byJoining: edges) + "."
    }

    public static func resolution(for moment: ConfirmationMoment, action: ConfirmationAction, rows: [CuratedRow]) -> (marks: [MarkChange], overrides: [BucketOverride]) {
        let rowsByID = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
        switch action {
        case .accept:
            return accept(moment)
        case .use(let id):
            guard moment.candidateIDs.contains(id) || moment.hiddenRunnerUpIDs.contains(id) else {
                return ([], [])
            }
            if id == moment.suggestedID {
                return accept(moment)
            }
            var marks = [MarkChange(photoID: id, flag: .pick)]
            var overrides: [BucketOverride] = []
            if let row = rowsByID[id], row.bucket != .selected, row.bucket != .protected {
                overrides.append(BucketOverride(photoID: id, bucket: .selected))
            }
            for other in moment.candidateIDs where other != id {
                marks.append(MarkChange(photoID: other, flag: .reject))
                if rowsByID[other]?.bucket == .selected {
                    overrides.append(BucketOverride(photoID: other, bucket: .alternate))
                }
            }
            return (marks, overrides)
        case .drop:
            return (
                [MarkChange(photoID: moment.suggestedID, flag: .reject)],
                [BucketOverride(photoID: moment.suggestedID, bucket: .hidden)]
            )
        }
    }

    private static func accept(_ moment: ConfirmationMoment) -> (marks: [MarkChange], overrides: [BucketOverride]) {
        var marks = [MarkChange(photoID: moment.suggestedID, flag: .pick)]
        for id in moment.candidateIDs where id != moment.suggestedID {
            marks.append(MarkChange(photoID: id, flag: .reject))
        }
        return (marks, [])
    }
}
