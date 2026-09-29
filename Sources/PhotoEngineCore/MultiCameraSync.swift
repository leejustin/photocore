import Foundation

/// Estimates clock offsets between cameras so second-shooter cards merge into one timeline.
public struct CameraTimeline: Sendable, Equatable {
    public var cameraKey: String
    public var offset: TimeInterval
    public var sampleCount: Int

    public init(cameraKey: String, offset: TimeInterval, sampleCount: Int) {
        self.cameraKey = cameraKey
        self.offset = offset
        self.sampleCount = sampleCount
    }
}

public enum MultiCameraSync {
    public static func cameraKey(for metadata: PhotoMetadata) -> String {
        let make = metadata.cameraMake?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let model = metadata.cameraModel?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let key = [make, model].filter { !$0.isEmpty }.joined(separator: " ")
        return key.isEmpty ? "unknown" : key
    }

    /// Pick the camera with the most photos as the reference timeline; estimate offsets for others
    /// by matching dense capture bursts within a ±3 minute search window.
    public static func estimateOffsets(assets: [PhotoAsset]) -> [CameraTimeline] {
        struct Sample {
            let key: String
            let time: TimeInterval
        }
        let samples: [Sample] = assets.compactMap { asset in
            guard let date = asset.metadata.captureDate else { return nil }
            return Sample(key: cameraKey(for: asset.metadata), time: date.timeIntervalSince1970)
        }
        let byCamera = Dictionary(grouping: samples, by: \.key)
        guard byCamera.count >= 2 else {
            return byCamera.keys.map { CameraTimeline(cameraKey: $0, offset: 0, sampleCount: byCamera[$0]?.count ?? 0) }
        }
        let reference = byCamera.max(by: { $0.value.count < $1.value.count })!.key
        let refTimes = byCamera[reference]!.map(\.time).sorted()

        var timelines = [CameraTimeline(cameraKey: reference, offset: 0, sampleCount: refTimes.count)]
        for (key, values) in byCamera where key != reference {
            let times = values.map(\.time).sorted()
            let offset = bestOffset(reference: refTimes, other: times)
            timelines.append(CameraTimeline(cameraKey: key, offset: offset, sampleCount: times.count))
        }
        return timelines.sorted { $0.sampleCount > $1.sampleCount }
    }

    public static func alignedDate(for asset: PhotoAsset, timelines: [CameraTimeline]) -> Date? {
        guard let date = asset.metadata.captureDate else { return nil }
        let key = cameraKey(for: asset.metadata)
        let offset = timelines.first(where: { $0.cameraKey == key })?.offset ?? 0
        return date.addingTimeInterval(offset)
    }

    /// Returns photos whose capture dates are shifted onto the reference camera timeline.
    public static func aligningCaptureDates(_ photos: [AnalyzedPhoto], timelines: [CameraTimeline]) -> [AnalyzedPhoto] {
        guard timelines.contains(where: { abs($0.offset) > 0.05 }) else { return photos }
        return photos.map { photo in
            guard let aligned = alignedDate(for: photo.asset, timelines: timelines),
                  aligned != photo.asset.metadata.captureDate else { return photo }
            var metadata = photo.asset.metadata
            metadata.captureDate = aligned
            let asset = PhotoAsset(
                id: photo.asset.id,
                url: photo.asset.url,
                relativePath: photo.asset.relativePath,
                metadata: metadata,
                sourceModifiedAt: photo.asset.sourceModifiedAt,
                sourceSignature: photo.asset.sourceSignature,
                contentHash: photo.asset.contentHash
            )
            return AnalyzedPhoto(asset: asset, signals: photo.signals)
        }
    }

    /// Search offsets from −180s…+180s in 0.5s steps; maximize burst co-occurrence.
    private static func bestOffset(reference: [TimeInterval], other: [TimeInterval]) -> TimeInterval {
        guard !reference.isEmpty, !other.isEmpty else { return 0 }
        var bestOffset: TimeInterval = 0
        var bestScore = -1
        var offset: TimeInterval = -180
        while offset <= 180 {
            var score = 0
            var i = 0
            var j = 0
            let shifted = other.map { $0 + offset }
            while i < reference.count, j < shifted.count {
                let delta = shifted[j] - reference[i]
                if abs(delta) <= 1.5 {
                    score += 1
                    i += 1
                    j += 1
                } else if delta < 0 {
                    j += 1
                } else {
                    i += 1
                }
            }
            if score > bestScore {
                bestScore = score
                bestOffset = offset
            }
            offset += 0.5
        }
        return bestOffset
    }
}
