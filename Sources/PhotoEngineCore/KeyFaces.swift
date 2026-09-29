import Foundation

/// Without person identity, boost frames that look like "the people who matter":
/// large faces, high capture quality, recurring in dense moments.
public enum KeyFaceScorer {
    public struct Boost: Sendable, Equatable {
        public var photoID: PhotoID
        public var amount: Double
        public var reason: String

        public init(photoID: PhotoID, amount: Double, reason: String) {
            self.photoID = photoID
            self.amount = amount
            self.reason = reason
        }
    }

    public static func boosts(for photos: [AnalyzedPhoto]) -> [PhotoID: Boost] {
        guard photos.count >= 8 else { return [:] }
        let faceAreas = photos.map { dominantFaceArea($0) }
        let qualities = photos.map(\.signals.faceQuality)
        let medianArea = median(faceAreas.filter { $0 > 0 })
        let medianQuality = median(qualities.filter { $0 > 0 })
        guard medianArea > 0, medianQuality > 0 else { return [:] }

        var result: [PhotoID: Boost] = [:]
        for photo in photos {
            let area = dominantFaceArea(photo)
            let quality = photo.signals.faceQuality
            guard photo.signals.faceCount > 0, area > 0 else { continue }
            let areaRatio = area / medianArea
            let qualityRatio = quality / max(medianQuality, 0.05)
            // Large + sharp faces get up to +0.08.
            let amount = min(0.08, max(0, (areaRatio - 1) * 0.04 + (qualityRatio - 1) * 0.03))
            guard amount >= 0.015 else { continue }
            result[photo.id] = Boost(
                photoID: photo.id,
                amount: amount,
                reason: photo.signals.faceCount > 1 ? "Key faces look strong" : "Key face looks strong"
            )
        }
        return result
    }

    private static func dominantFaceArea(_ photo: AnalyzedPhoto) -> Double {
        photo.signals.faces.map { $0.boundingBox.width * $0.boundingBox.height }.max() ?? 0
    }

    private static func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        if sorted.count % 2 == 0 {
            return (sorted[mid - 1] + sorted[mid]) / 2
        }
        return sorted[mid]
    }
}
