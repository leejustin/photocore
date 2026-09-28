import Foundation
import PhotoEngineApple
import PhotoEngineCore

public struct CuratedRow: Identifiable, Sendable, Equatable {
    public let id: PhotoID
    public let bucket: SelectionBucket
    public let rank: Int?
    public let relativePath: String
    public let reasons: [String]
    public let score: Double
    public let sourceURL: URL
    public let previewURL: URL?

    public init(id: PhotoID, bucket: SelectionBucket, rank: Int?, relativePath: String, reasons: [String], score: Double, sourceURL: URL, previewURL: URL?) {
        self.id = id
        self.bucket = bucket
        self.rank = rank
        self.relativePath = relativePath
        self.reasons = reasons
        self.score = score
        self.sourceURL = sourceURL
        self.previewURL = previewURL
    }

    public static func rows(for result: PipelineResult) -> [CuratedRow] {
        let analyzedByID = Dictionary(uniqueKeysWithValues: result.analyzed.map { ($0.id, $0) })
        let scoreByID = Dictionary(uniqueKeysWithValues: result.scored.map { ($0.id, $0.score) })
        let exportByID = Dictionary(uniqueKeysWithValues: result.exports.map { ($0.photoID, URL(fileURLWithPath: $0.outputPath)) })
        return result.shortlist.decisions.compactMap { decision in
            guard let analyzed = analyzedByID[decision.photoID] else { return nil }
            return CuratedRow(
                id: decision.photoID,
                bucket: decision.bucket,
                rank: decision.rank,
                relativePath: analyzed.asset.relativePath,
                reasons: scoreByID[decision.photoID]?.reasons ?? decision.reasons,
                score: decision.score,
                sourceURL: analyzed.asset.url,
                previewURL: exportByID[decision.photoID]
            )
        }
    }
}

public enum PhotoGroupIndex {
    public static func build(_ grouping: PhotoGrouping) -> [PhotoID: PhotoGroup] {
        var map: [PhotoID: PhotoGroup] = [:]
        let ordered = grouping.groups.sorted { rank($0.kind) < rank($1.kind) }
        for group in ordered where group.memberIDs.count > 1 {
            for id in group.memberIDs {
                map[id] = group
            }
        }
        return map
    }

    private static func rank(_ kind: PhotoGroup.Kind) -> Int {
        switch kind {
        case .scene: 0
        case .burst: 1
        case .exactDuplicate: 2
        }
    }
}
