import Foundation

public struct PhotoID: Hashable, Codable, Sendable, CustomStringConvertible {
    public let rawValue: UUID

    public init(_ rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }

    public var description: String { rawValue.uuidString }
}

public struct ImportID: Hashable, Codable, Sendable {
    public let rawValue: UUID

    public init(_ rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }
}

public enum PhotoFormat: String, Codable, Sendable {
    case jpeg
    case heic
    case heif
    case unknown
}

public struct PhotoMetadata: Codable, Sendable, Equatable {
    public var pixelWidth: Int
    public var pixelHeight: Int
    public var orientation: Int
    public var captureDate: Date?
    public var cameraMake: String?
    public var cameraModel: String?
    public var lensModel: String?
    public var fileSize: Int64
    public var format: PhotoFormat

    public init(
        pixelWidth: Int,
        pixelHeight: Int,
        orientation: Int = 1,
        captureDate: Date? = nil,
        cameraMake: String? = nil,
        cameraModel: String? = nil,
        lensModel: String? = nil,
        fileSize: Int64 = 0,
        format: PhotoFormat = .unknown
    ) {
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.orientation = orientation
        self.captureDate = captureDate
        self.cameraMake = cameraMake
        self.cameraModel = cameraModel
        self.lensModel = lensModel
        self.fileSize = fileSize
        self.format = format
    }
}

public struct PhotoAsset: Identifiable, Codable, Sendable, Equatable {
    public let id: PhotoID
    public let url: URL
    public let relativePath: String
    public let metadata: PhotoMetadata
    public let sourceModifiedAt: Date?
    /// A cheap content signature used to invalidate cached analysis even when
    /// a file is replaced while preserving its size and modification date.
    public let sourceSignature: String?

    public init(
        id: PhotoID = PhotoID(),
        url: URL,
        relativePath: String,
        metadata: PhotoMetadata,
        sourceModifiedAt: Date? = nil,
        sourceSignature: String? = nil
    ) {
        self.id = id
        self.url = url
        self.relativePath = relativePath
        self.metadata = metadata
        self.sourceModifiedAt = sourceModifiedAt
        self.sourceSignature = sourceSignature
    }
}

public struct PhotoFingerprint: Codable, Sendable, Equatable {
    public var contentHash: String
    public var perceptualHash: UInt64

    public init(contentHash: String, perceptualHash: UInt64) {
        self.contentHash = contentHash
        self.perceptualHash = perceptualHash
    }
}

public struct FaceSignal: Codable, Sendable, Equatable {
    public var boundingBox: CGRectCodable
    public var captureQuality: Double?

    public init(boundingBox: CGRectCodable, captureQuality: Double?) {
        self.boundingBox = boundingBox
        self.captureQuality = captureQuality
    }
}

public struct CGRectCodable: Codable, Sendable, Equatable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

public struct AnalysisSignals: Codable, Sendable, Equatable {
    public var fingerprint: PhotoFingerprint
    public var brightness: Double
    public var exposureQuality: Double
    public var sharpness: Double
    public var faceQuality: Double
    public var faceCount: Int
    public var aestheticScore: Double?
    public var aestheticUtility: Bool?
    /// A platform-owned, versioned visual descriptor. The core deliberately
    /// treats this as opaque data and asks an injected distance provider to
    /// compare it instead of making assumptions about the vector's metric.
    public var featurePrint: Data?
    public var faces: [FaceSignal]

    public init(
        fingerprint: PhotoFingerprint,
        brightness: Double,
        exposureQuality: Double,
        sharpness: Double,
        faceQuality: Double,
        faceCount: Int,
        aestheticScore: Double?,
        aestheticUtility: Bool?,
        featurePrint: Data?,
        faces: [FaceSignal]
    ) {
        self.fingerprint = fingerprint
        self.brightness = brightness
        self.exposureQuality = exposureQuality
        self.sharpness = sharpness
        self.faceQuality = faceQuality
        self.faceCount = faceCount
        self.aestheticScore = aestheticScore
        self.aestheticUtility = aestheticUtility
        self.featurePrint = featurePrint
        self.faces = faces
    }

    public func removingFeaturePrint() -> AnalysisSignals {
        var copy = self
        copy.featurePrint = nil
        return copy
    }
}

public struct AnalyzedPhoto: Identifiable, Codable, Sendable, Equatable {
    public let asset: PhotoAsset
    public let signals: AnalysisSignals

    public var id: PhotoID { asset.id }

    public init(asset: PhotoAsset, signals: AnalysisSignals) {
        self.asset = asset
        self.signals = signals
    }

    public func removingFeaturePrint() -> AnalyzedPhoto {
        AnalyzedPhoto(asset: asset, signals: signals.removingFeaturePrint())
    }
}

public enum CurationMode: String, Codable, CaseIterable, Sendable {
    case everyday
    case groupEvent
    case trip
    case creative

    public var displayName: String {
        switch self {
        case .everyday: "Everyday"
        case .groupEvent: "Group event"
        case .trip: "Trip"
        case .creative: "Creative"
        }
    }
}

public struct ScoringProfile: Codable, Sendable, Equatable {
    public var mode: CurationMode
    public var sharpnessWeight: Double
    public var exposureWeight: Double
    public var faceWeight: Double
    public var aestheticWeight: Double
    public var diversityWeight: Double
    public var targetCount: Int
    public var burstWindow: TimeInterval
    public var nearDuplicateHammingDistance: Int
    public var nearDuplicateVisualDistance: Double

    public init(
        mode: CurationMode,
        sharpnessWeight: Double,
        exposureWeight: Double,
        faceWeight: Double,
        aestheticWeight: Double,
        diversityWeight: Double,
        targetCount: Int,
        burstWindow: TimeInterval,
        nearDuplicateHammingDistance: Int,
        nearDuplicateVisualDistance: Double
    ) {
        self.mode = mode
        self.sharpnessWeight = sharpnessWeight
        self.exposureWeight = exposureWeight
        self.faceWeight = faceWeight
        self.aestheticWeight = aestheticWeight
        self.diversityWeight = diversityWeight
        self.targetCount = targetCount
        self.burstWindow = burstWindow
        self.nearDuplicateHammingDistance = nearDuplicateHammingDistance
        self.nearDuplicateVisualDistance = nearDuplicateVisualDistance
    }

    public static func `default`(for mode: CurationMode) -> ScoringProfile {
        switch mode {
        case .everyday:
            ScoringProfile(mode: mode, sharpnessWeight: 0.30, exposureWeight: 0.22, faceWeight: 0.20, aestheticWeight: 0.28, diversityWeight: 0.55, targetCount: 40, burstWindow: 12, nearDuplicateHammingDistance: 8, nearDuplicateVisualDistance: 8)
        case .groupEvent:
            ScoringProfile(mode: mode, sharpnessWeight: 0.24, exposureWeight: 0.16, faceWeight: 0.36, aestheticWeight: 0.24, diversityWeight: 0.70, targetCount: 50, burstWindow: 15, nearDuplicateHammingDistance: 9, nearDuplicateVisualDistance: 9)
        case .trip:
            ScoringProfile(mode: mode, sharpnessWeight: 0.24, exposureWeight: 0.18, faceWeight: 0.10, aestheticWeight: 0.48, diversityWeight: 0.82, targetCount: 60, burstWindow: 20, nearDuplicateHammingDistance: 8, nearDuplicateVisualDistance: 8)
        case .creative:
            ScoringProfile(mode: mode, sharpnessWeight: 0.12, exposureWeight: 0.10, faceWeight: 0.12, aestheticWeight: 0.66, diversityWeight: 0.90, targetCount: 60, burstWindow: 25, nearDuplicateHammingDistance: 10, nearDuplicateVisualDistance: 10)
        }
    }
}

public struct CompositeScore: Codable, Sendable, Equatable {
    public var total: Double
    public var components: [String: Double]
    public var reasons: [String]

    public init(total: Double, components: [String: Double], reasons: [String]) {
        self.total = total
        self.components = components
        self.reasons = reasons
    }
}

public struct ScoredPhoto: Identifiable, Codable, Sendable, Equatable {
    public let photo: AnalyzedPhoto
    public let score: CompositeScore

    public var id: PhotoID { photo.id }

    public init(photo: AnalyzedPhoto, score: CompositeScore) {
        self.photo = photo
        self.score = score
    }
}

public struct PhotoGroup: Identifiable, Codable, Sendable, Equatable {
    public let id: UUID
    public let memberIDs: [PhotoID]
    public let kind: Kind

    public enum Kind: String, Codable, Sendable {
        case exactDuplicate
        case burst
        case scene
    }

    public init(id: UUID = UUID(), memberIDs: [PhotoID], kind: Kind) {
        self.id = id
        self.memberIDs = memberIDs
        self.kind = kind
    }
}

public struct PhotoGrouping: Codable, Sendable, Equatable {
    public var groups: [PhotoGroup]

    public init(groups: [PhotoGroup]) {
        self.groups = groups
    }
}

public enum SelectionBucket: String, Codable, Sendable {
    case selected
    case alternate
    case review
    case hidden
}

public struct SelectionDecision: Identifiable, Codable, Sendable, Equatable {
    public let id: UUID
    public let photoID: PhotoID
    public let bucket: SelectionBucket
    public let rank: Int?
    public let reasons: [String]
    public let score: Double

    public init(id: UUID = UUID(), photoID: PhotoID, bucket: SelectionBucket, rank: Int?, reasons: [String], score: Double) {
        self.id = id
        self.photoID = photoID
        self.bucket = bucket
        self.rank = rank
        self.reasons = reasons
        self.score = score
    }
}

public struct Shortlist: Codable, Sendable, Equatable {
    public var decisions: [SelectionDecision]
    public var selectedIDs: [PhotoID] { decisions.filter { $0.bucket == .selected }.sorted { ($0.rank ?? .max) < ($1.rank ?? .max) }.map(\.photoID) }

    public init(decisions: [SelectionDecision]) {
        self.decisions = decisions
    }
}

public struct EditRecipe: Codable, Sendable, Equatable {
    public var exposure: Double
    public var contrast: Double
    public var saturation: Double
    public var highlights: Double
    public var shadows: Double
    public var sharpening: Double

    public init(exposure: Double = 0, contrast: Double = 0, saturation: Double = 0, highlights: Double = 0, shadows: Double = 0, sharpening: Double = 0) {
        self.exposure = exposure
        self.contrast = contrast
        self.saturation = saturation
        self.highlights = highlights
        self.shadows = shadows
        self.sharpening = sharpening
    }
}

public struct ExportedPhoto: Codable, Sendable, Equatable {
    public let photoID: PhotoID
    public let sourcePath: String
    public let outputPath: String
    public let recipe: EditRecipe

    public init(photoID: PhotoID, sourcePath: String, outputPath: String, recipe: EditRecipe) {
        self.photoID = photoID
        self.sourcePath = sourcePath
        self.outputPath = outputPath
        self.recipe = recipe
    }
}

public struct PipelineManifest: Codable, Sendable, Equatable {
    public let schemaVersion: Int
    public let pipelineVersion: String
    public let createdAt: Date
    public let sourceFolder: String
    public let mode: CurationMode
    public let assets: [PhotoAsset]
    public let analyzed: [AnalyzedPhoto]
    public let grouping: PhotoGrouping
    public let shortlist: Shortlist
    public let exports: [ExportedPhoto]
    public let warnings: [String]

    public init(
        schemaVersion: Int = 2,
        pipelineVersion: String = "0.2.0",
        createdAt: Date = Date(),
        sourceFolder: String,
        mode: CurationMode,
        assets: [PhotoAsset],
        analyzed: [AnalyzedPhoto],
        grouping: PhotoGrouping,
        shortlist: Shortlist,
        exports: [ExportedPhoto],
        warnings: [String] = []
    ) {
        self.schemaVersion = schemaVersion
        self.pipelineVersion = pipelineVersion
        self.createdAt = createdAt
        self.sourceFolder = sourceFolder
        self.mode = mode
        self.assets = assets
        self.analyzed = analyzed
        self.grouping = grouping
        self.shortlist = shortlist
        self.exports = exports
        self.warnings = warnings
    }
}

public enum PhotoEngineError: LocalizedError, Sendable {
    case invalidFolder(URL)
    case unreadableImage(URL)
    case unsupportedImage(URL)
    case invalidArgument(String)
    case noPhotos(URL)
    case exportFailed(URL, String)
    case unsafeOutputDirectory(source: URL, output: URL)

    public var errorDescription: String {
        switch self {
        case .invalidFolder(let url): "Not a readable folder: \(url.path)"
        case .unreadableImage(let url): "Could not read image: \(url.path)"
        case .unsupportedImage(let url): "Unsupported image format: \(url.path)"
        case .invalidArgument(let message): message
        case .noPhotos(let url): "No supported photos found in \(url.path)"
        case .exportFailed(let url, let message): "Could not export \(url.lastPathComponent): \(message)"
        case .unsafeOutputDirectory(let source, let output): "Output folder \(output.path) must not be the source folder or live inside it (\(source.path))."
        }
    }
}

public enum PhotoSimilarity {
    public static func hammingDistance(_ lhs: UInt64, _ rhs: UInt64) -> Int {
        (lhs ^ rhs).nonzeroBitCount
    }

    public static func normalizedHammingDistance(_ lhs: UInt64, _ rhs: UInt64) -> Double {
        Double(hammingDistance(lhs, rhs)) / 64.0
    }
}

public typealias VisualDistanceProvider = @Sendable (AnalysisSignals, AnalysisSignals) -> Double?

public enum PhotoScoring {
    public static func score(_ photo: AnalyzedPhoto, profile: ScoringProfile) -> CompositeScore {
        let signals = photo.signals
        let rawAesthetic = signals.aestheticScore ?? 0.5
        // Vision marks receipts, screenshots, and similar documentary images as
        // utility content. Keep them selectable, but do not let an aesthetic
        // score make them dominate a photographic shortlist.
        let aesthetic = signals.aestheticUtility == true ? min(rawAesthetic, 0.5) : rawAesthetic
        let face = signals.faceCount == 0 ? 0.5 : signals.faceQuality
        let total =
            signals.sharpness * profile.sharpnessWeight +
            signals.exposureQuality * profile.exposureWeight +
            face * profile.faceWeight +
            aesthetic * profile.aestheticWeight

        var reasons: [String] = []
        if signals.sharpness >= 0.65 { reasons.append("sharp") }
        if signals.exposureQuality >= 0.65 { reasons.append("well exposed") }
        if signals.faceCount > 0 && face >= 0.65 { reasons.append("strong faces") }
        if aesthetic >= 0.65 { reasons.append("aesthetic") }
        if reasons.isEmpty { reasons.append("best available candidate") }

        return CompositeScore(
            total: min(max(total, 0), 1),
            components: [
                "sharpness": signals.sharpness,
                "exposure": signals.exposureQuality,
                "faceQuality": face,
                "aesthetic": aesthetic
            ],
            reasons: reasons
        )
    }
}

public enum PhotoGroupingEngine {
    private struct ContentUnit {
        let memberIndices: [Int]
        let representativeIndex: Int
        let captureDate: Date?
    }

    private struct WorkingCluster {
        var units: [ContentUnit]
        let representativeIndex: Int
        var latestDate: Date?
    }

    public static func group(
        _ photos: [AnalyzedPhoto],
        profile: ScoringProfile,
        visualDistance: VisualDistanceProvider = { _, _ in nil }
    ) -> PhotoGrouping {
        guard photos.count > 1 else { return PhotoGrouping(groups: []) }

        // Exact copies form a content unit before any visual comparisons. This
        // finds them globally without an O(n²) scan.
        let indicesByHash = Dictionary(grouping: photos.indices) {
            photos[$0].signals.fingerprint.contentHash
        }
        var units = indicesByHash.values.map { indices -> ContentUnit in
            let ordered = indices.sorted { lhs, rhs in
                let leftDate = photos[lhs].asset.metadata.captureDate ?? .distantPast
                let rightDate = photos[rhs].asset.metadata.captureDate ?? .distantPast
                return leftDate == rightDate ? lhs < rhs : leftDate < rightDate
            }
            let representative = ordered[0]
            return ContentUnit(
                memberIndices: ordered,
                representativeIndex: representative,
                captureDate: photos[representative].asset.metadata.captureDate
            )
        }
        units.sort {
            let leftDate = $0.captureDate ?? .distantFuture
            let rightDate = $1.captureDate ?? .distantFuture
            return leftDate == rightDate ? $0.representativeIndex < $1.representativeIndex : leftDate < rightDate
        }

        // Greedy, fixed-representative burst clustering prevents transitive
        // A~B~C chains. Comparisons are restricted to recent clusters and
        // capped so a pathological same-timestamp import remains bounded.
        var clusters: [WorkingCluster] = []
        let maximumCandidateClusters = 128
        for unit in units {
            guard let date = unit.captureDate else {
                clusters.append(WorkingCluster(units: [unit], representativeIndex: unit.representativeIndex, latestDate: nil))
                continue
            }

            var matchedCluster: Int?
            var compared = 0
            for clusterIndex in clusters.indices.reversed() {
                guard compared < maximumCandidateClusters else { break }
                guard let latestDate = clusters[clusterIndex].latestDate else { continue }
                let interval = date.timeIntervalSince(latestDate)
                if interval > profile.burstWindow { break }
                guard interval >= -profile.burstWindow else { continue }
                compared += 1

                let left = photos[unit.representativeIndex]
                let right = photos[clusters[clusterIndex].representativeIndex]
                let hamming = PhotoSimilarity.hammingDistance(
                    left.signals.fingerprint.perceptualHash,
                    right.signals.fingerprint.perceptualHash
                )
                let visionDistance = visualDistance(left.signals, right.signals)
                let close = hamming <= profile.nearDuplicateHammingDistance ||
                    (visionDistance.map { $0 <= profile.nearDuplicateVisualDistance } ?? false)
                if close {
                    matchedCluster = clusterIndex
                    break
                }
            }

            if let matchedCluster {
                var cluster = clusters.remove(at: matchedCluster)
                cluster.units.append(unit)
                cluster.latestDate = date
                // Keep clusters ordered by their latest observation so the
                // reverse scan can stop as soon as it leaves the burst window.
                clusters.append(cluster)
            } else {
                clusters.append(WorkingCluster(units: [unit], representativeIndex: unit.representativeIndex, latestDate: date))
            }
        }

        let groups = clusters.compactMap { cluster -> PhotoGroup? in
            let indices = cluster.units.flatMap(\.memberIndices)
            guard indices.count > 1 else { return nil }
            let kind: PhotoGroup.Kind = cluster.units.count == 1 ? .exactDuplicate : .burst
            return PhotoGroup(memberIDs: indices.map { photos[$0].id }, kind: kind)
        }
        return PhotoGrouping(groups: groups.sorted {
            let left = $0.memberIDs.first?.description ?? ""
            let right = $1.memberIDs.first?.description ?? ""
            return left < right
        })
    }
}

public enum PhotoSelectionEngine {
    public static func select(
        _ photos: [ScoredPhoto],
        grouping: PhotoGrouping,
        profile: ScoringProfile,
        visualDistance: VisualDistanceProvider = { _, _ in nil }
    ) -> Shortlist {
        guard !photos.isEmpty else { return Shortlist(decisions: []) }
        let byID = Dictionary(uniqueKeysWithValues: photos.map { ($0.id, $0) })
        var groupedIDs = Set<PhotoID>()
        var decisions: [SelectionDecision] = []
        var candidates: [ScoredPhoto] = []

        for group in grouping.groups {
            let members = group.memberIDs.compactMap { byID[$0] }
            let contentBuckets = Dictionary(grouping: members) {
                $0.photo.signals.fingerprint.contentHash
            }
            let bucketRepresentatives = contentBuckets.values.compactMap {
                $0.max { $0.score.total < $1.score.total }
            }
            guard let best = bucketRepresentatives.max(by: { $0.score.total < $1.score.total }) else { continue }
            groupedIDs.formUnion(group.memberIDs)
            candidates.append(best)

            for bucketMembers in contentBuckets.values {
                let ordered = bucketMembers.sorted { $0.score.total > $1.score.total }
                guard let representative = ordered.first else { continue }
                if representative.id != best.id {
                    decisions.append(SelectionDecision(
                        photoID: representative.id,
                        bucket: .alternate,
                        rank: nil,
                        reasons: ["near-duplicate of a stronger candidate"],
                        score: representative.score.total
                    ))
                }
                for duplicate in ordered.dropFirst() {
                    decisions.append(SelectionDecision(
                        photoID: duplicate.id,
                        bucket: .hidden,
                        rank: nil,
                        reasons: ["exact duplicate of a stronger candidate"],
                        score: duplicate.score.total
                    ))
                }
            }
        }

        candidates.append(contentsOf: photos.filter { !groupedIDs.contains($0.id) })
        candidates.sort { $0.score.total > $1.score.total }

        var selected: [ScoredPhoto] = []
        var remaining = candidates
        while selected.count < profile.targetCount, !remaining.isEmpty {
            var bestIndex = 0
            var bestValue = -Double.infinity
            for (index, candidate) in remaining.enumerated() {
                let redundancy = selected.map { selectedPhoto -> Double in
                    if let distance = visualDistance(candidate.photo.signals, selectedPhoto.photo.signals) {
                        // Vision distances are unbounded; convert them into a
                        // smooth 0...1 similarity for maximal-marginal relevance.
                        return exp(-distance / max(profile.nearDuplicateVisualDistance, 0.001))
                    }
                    let normalized = PhotoSimilarity.normalizedHammingDistance(
                        candidate.photo.signals.fingerprint.perceptualHash,
                        selectedPhoto.photo.signals.fingerprint.perceptualHash
                    )
                    return 1 - normalized
                }.max() ?? 0
                let value = candidate.score.total - profile.diversityWeight * redundancy
                if value > bestValue {
                    bestValue = value
                    bestIndex = index
                }
            }
            selected.append(remaining.remove(at: bestIndex))
        }

        for (rank, photo) in selected.enumerated() {
            decisions.append(SelectionDecision(photoID: photo.id, bucket: .selected, rank: rank, reasons: photo.score.reasons, score: photo.score.total))
        }

        for photo in remaining {
            decisions.append(SelectionDecision(photoID: photo.id, bucket: .review, rank: nil, reasons: ["below shortlist target"], score: photo.score.total))
        }

        return Shortlist(decisions: decisions)
    }
}
