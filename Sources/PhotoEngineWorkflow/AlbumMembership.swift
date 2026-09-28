import Foundation
import PhotoEngineCore

public enum AlbumMembership {
    /// In the album unless the user rejected it: AI keepers, protected photos, and the user's own picks.
    public static func contains(_ row: CuratedRow, mark: PhotoReviewMark) -> Bool {
        if mark.flag == .reject { return false }
        return row.bucket == .selected || row.bucket == .protected || mark.flag == .pick
    }
}

public struct AlbumSummary: Sendable, Equatable {
    public var total: Int
    public var kept: Int
    public var unusable: Int
    public var close: Int
    public var pending: Int

    public init(total: Int, kept: Int, unusable: Int, close: Int, pending: Int) {
        self.total = total
        self.kept = kept
        self.unusable = unusable
        self.close = close
        self.pending = pending
    }

    public var sentence: String {
        "\(kept) kept from \(total)."
    }

    public static func make(rows: [CuratedRow], marks: [PhotoID: PhotoReviewMark], pendingConfirmations: Int) -> AlbumSummary {
        let kept = rows.filter { row in
            AlbumMembership.contains(row, mark: marks[row.id] ?? PhotoReviewMark(photoID: row.id))
        }.count
        let unusable = rows.filter { $0.reasons.contains(where: PhotoTechnicalReject.isTechnicalRejectReason) }.count
        let close = rows.filter { $0.bucket == .review }.count
        return AlbumSummary(
            total: rows.count,
            kept: kept,
            unusable: unusable,
            close: close,
            pending: pendingConfirmations
        )
    }
}
