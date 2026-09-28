import Foundation
import PhotoEngineApple
import PhotoEngineCore

public struct CurationSession: Sendable {
    public var result: PipelineResult
    public var rows: [CuratedRow]
    public var groupsByPhoto: [PhotoID: PhotoGroup]
    public var marks: [PhotoID: PhotoReviewMark]
    public var customRecipes: [PhotoID: EditRecipe]
    public var lookSettings: LookSettings

    public init(result: PipelineResult, marks: [PhotoID: PhotoReviewMark] = [:], customRecipes: [PhotoID: EditRecipe] = [:], lookSettings: LookSettings) {
        self.result = result
        self.rows = CuratedRow.rows(for: result)
        self.groupsByPhoto = PhotoGroupIndex.build(result.grouping)
        self.marks = marks
        self.customRecipes = customRecipes
        self.lookSettings = lookSettings
    }

    public func mark(for id: PhotoID) -> PhotoReviewMark {
        marks[id] ?? PhotoReviewMark(photoID: id)
    }

    public func row(for id: PhotoID) -> CuratedRow? {
        rows.first { $0.id == id }
    }

    public mutating func apply(markChanges: [MarkChange]) {
        for change in markChanges {
            var mark = mark(for: change.photoID)
            mark.flag = change.flag
            marks[change.photoID] = mark
        }
    }

    public var deliverRows: [CuratedRow] {
        let analyzed = Dictionary(uniqueKeysWithValues: result.analyzed.map { ($0.id, $0) })
        return rows.filter { AlbumMembership.contains($0, mark: mark(for: $0.id)) }.sorted { lhs, rhs in
            let left = analyzed[lhs.id]?.asset.metadata.captureDate ?? .distantFuture
            let right = analyzed[rhs.id]?.asset.metadata.captureDate ?? .distantFuture
            return left == right ? (lhs.rank ?? .max) < (rhs.rank ?? .max) : left < right
        }
    }

    public var confirmations: (moments: [ConfirmationMoment], beyondCap: Int) {
        ConfirmationBuilder.build(result: result, rows: rows, groups: groupsByPhoto)
    }
}
