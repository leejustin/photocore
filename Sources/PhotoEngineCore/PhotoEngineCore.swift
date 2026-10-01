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

public struct SessionID: Hashable, Codable, Sendable, CustomStringConvertible {
    public let rawValue: UUID

    public init(_ rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }

    public var description: String { rawValue.uuidString }
}

public enum PhotoFormat: String, Codable, Sendable {
    case jpeg
    case heic
    case heif
    case raw
    case dng
    case unknown

    public var isRawMaster: Bool {
        self == .raw || self == .dng
    }
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
    /// In-camera or prior XMP rating when present (0...5).
    public var rating: Int?

    public init(
        pixelWidth: Int,
        pixelHeight: Int,
        orientation: Int = 1,
        captureDate: Date? = nil,
        cameraMake: String? = nil,
        cameraModel: String? = nil,
        lensModel: String? = nil,
        fileSize: Int64 = 0,
        format: PhotoFormat = .unknown,
        rating: Int? = nil
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
        self.rating = rating
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
    /// A verified full-file digest when discovery has already paid for it.
    /// This enables exact-content analysis reuse without making the core
    /// depend on a particular hashing implementation.
    public let contentHash: String?

    public init(
        id: PhotoID = PhotoID(),
        url: URL,
        relativePath: String,
        metadata: PhotoMetadata,
        sourceModifiedAt: Date? = nil,
        sourceSignature: String? = nil,
        contentHash: String? = nil
    ) {
        self.id = id
        self.url = url
        self.relativePath = relativePath
        self.metadata = metadata
        self.sourceModifiedAt = sourceModifiedAt
        self.sourceSignature = sourceSignature
        self.contentHash = contentHash
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
    /// 0 closed … 1 wide open, when landmarks were available.
    public var eyeOpenness: Double?

    public init(boundingBox: CGRectCodable, captureQuality: Double?, eyeOpenness: Double? = nil) {
        self.boundingBox = boundingBox
        self.captureQuality = captureQuality
        self.eyeOpenness = eyeOpenness
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
    public var subjectSharpness: Double?
    public var subjectConfidence: Double
    public var faceQuality: Double
    public var faceCount: Int
    public var aestheticScore: Double?
    public var aestheticUtility: Bool?
    /// A platform-owned, versioned visual descriptor. The core deliberately
    /// treats this as opaque data and asks an injected distance provider to
    /// compare it instead of making assumptions about the vector's metric.
    public var featurePrint: Data?
    public var faces: [FaceSignal]
    public var qualityFlags: [String]
    /// Laplacian energy of the sharpest regions. Raw units; compare only within a shoot.
    public var focusEnergy: Double?

    public init(
        fingerprint: PhotoFingerprint,
        brightness: Double,
        exposureQuality: Double,
        sharpness: Double,
        subjectSharpness: Double? = nil,
        subjectConfidence: Double = 0,
        faceQuality: Double,
        faceCount: Int,
        aestheticScore: Double?,
        aestheticUtility: Bool?,
        featurePrint: Data?,
        faces: [FaceSignal],
        qualityFlags: [String] = [],
        focusEnergy: Double? = nil
    ) {
        self.fingerprint = fingerprint
        self.brightness = brightness
        self.exposureQuality = exposureQuality
        self.sharpness = sharpness
        self.subjectSharpness = subjectSharpness
        self.subjectConfidence = subjectConfidence
        self.faceQuality = faceQuality
        self.faceCount = faceCount
        self.aestheticScore = aestheticScore
        self.aestheticUtility = aestheticUtility
        self.featurePrint = featurePrint
        self.faces = faces
        self.qualityFlags = qualityFlags
        self.focusEnergy = focusEnergy
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
    case wedding
    case family
    case newborn
    case sports
    case phoneDump

    public var displayName: String {
        switch self {
        case .everyday: "Everyday"
        case .groupEvent: "Group event"
        case .trip: "Trip"
        case .creative: "Creative"
        case .wedding: "Wedding"
        case .family: "Family"
        case .newborn: "Newborn"
        case .sports: "Sports"
        case .phoneDump: "Phone dump"
        }
    }

    public var cullHint: String {
        switch self {
        case .everyday:
            "Drops blur, blank frames, and unusable exposures before you confirm."
        case .groupEvent, .wedding, .family:
            "Protects faces: soft subjects, blinks, and blank frames leave the album."
        case .trip:
            "Keeps landscapes and scenes; only blur, utility shots, and bad exposures leave."
        case .creative:
            "Only extreme blur and unusable exposures are hard rejects. Soft and unusual frames stay."
        case .newborn:
            "Closed eyes are fine. Still drops blur, blanks, and unusable exposures."
        case .sports:
            "Allows motion blur more often. Still drops blanks and unusable exposures."
        case .phoneDump:
            "Skips screenshots-style junk in analysis and keeps a tighter everyday cull."
        }
    }
}

/// Occasion-aware rules for frames that should never compete for the shortlist.
public struct RejectionPolicy: Codable, Sendable, Equatable {
    public var rejectExtremeBlur: Bool
    public var rejectNoSubject: Bool
    public var rejectUnusableExposure: Bool
    /// When true, "no clear subject" only applies to Vision utility / accidental shots.
    public var noSubjectRequiresUtility: Bool
    public var facesMatter: Bool
    public var closedEyesMatter: Bool
    /// Soften the extreme-blur cutoff for action sports.
    public var allowMotionBlur: Bool

    public init(
        rejectExtremeBlur: Bool = true,
        rejectNoSubject: Bool = true,
        rejectUnusableExposure: Bool = true,
        noSubjectRequiresUtility: Bool = false,
        facesMatter: Bool = true,
        closedEyesMatter: Bool = true,
        allowMotionBlur: Bool = false
    ) {
        self.rejectExtremeBlur = rejectExtremeBlur
        self.rejectNoSubject = rejectNoSubject
        self.rejectUnusableExposure = rejectUnusableExposure
        self.noSubjectRequiresUtility = noSubjectRequiresUtility
        self.facesMatter = facesMatter
        self.closedEyesMatter = closedEyesMatter
        self.allowMotionBlur = allowMotionBlur
    }

    public static func `default`(for mode: CurationMode) -> RejectionPolicy {
        switch mode {
        case .everyday, .phoneDump:
            RejectionPolicy()
        case .groupEvent, .wedding, .family:
            RejectionPolicy(facesMatter: true, closedEyesMatter: true)
        case .trip:
            RejectionPolicy(noSubjectRequiresUtility: true, facesMatter: false, closedEyesMatter: false)
        case .creative:
            RejectionPolicy(rejectNoSubject: false, facesMatter: false, closedEyesMatter: false)
        case .newborn:
            RejectionPolicy(closedEyesMatter: false)
        case .sports:
            RejectionPolicy(closedEyesMatter: false, allowMotionBlur: true)
        }
    }

    private enum CodingKeys: String, CodingKey {
        case rejectExtremeBlur, rejectNoSubject, rejectUnusableExposure
        case noSubjectRequiresUtility, facesMatter, closedEyesMatter, allowMotionBlur
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        rejectExtremeBlur = try container.decodeIfPresent(Bool.self, forKey: .rejectExtremeBlur) ?? true
        rejectNoSubject = try container.decodeIfPresent(Bool.self, forKey: .rejectNoSubject) ?? true
        rejectUnusableExposure = try container.decodeIfPresent(Bool.self, forKey: .rejectUnusableExposure) ?? true
        noSubjectRequiresUtility = try container.decodeIfPresent(Bool.self, forKey: .noSubjectRequiresUtility) ?? false
        facesMatter = try container.decodeIfPresent(Bool.self, forKey: .facesMatter) ?? true
        closedEyesMatter = try container.decodeIfPresent(Bool.self, forKey: .closedEyesMatter) ?? true
        allowMotionBlur = try container.decodeIfPresent(Bool.self, forKey: .allowMotionBlur) ?? false
    }
}

public enum PhotoTechnicalReject {
    public static let extremeBlur = "extreme blur"
    public static let noClearSubject = "no clear subject"
    public static let unusableExposure = "unusable exposure"
    public static let eyesClosed = "eyes appear closed"

    public static let allFlags: Set<String> = [extremeBlur, noClearSubject, unusableExposure, eyesClosed]

    public static func isTechnicalRejectReason(_ reason: String) -> Bool {
        reason.hasPrefix("technical reject:")
    }

    /// Returns a shortlist reason when this photo must be hidden under the policy.
    public static func reason(for signals: AnalysisSignals, policy: RejectionPolicy) -> String? {
        let flags = Set(signals.qualityFlags)
        if policy.rejectExtremeBlur, flags.contains(extremeBlur), !policy.allowMotionBlur {
            return "technical reject: extreme blur"
        }
        if policy.rejectExtremeBlur, policy.allowMotionBlur, flags.contains(extremeBlur), signals.sharpness < 0.03 {
            return "technical reject: extreme blur"
        }
        if policy.rejectUnusableExposure, flags.contains(unusableExposure) {
            return "technical reject: unusable exposure"
        }
        if policy.rejectNoSubject, flags.contains(noClearSubject) {
            if policy.noSubjectRequiresUtility {
                if signals.aestheticUtility == true {
                    return "technical reject: no clear subject"
                }
            } else {
                return "technical reject: no clear subject"
            }
        }
        if policy.closedEyesMatter, flags.contains(eyesClosed), signals.faceCount == 1 {
            return "technical reject: eyes appear closed"
        }
        return nil
    }
}

public enum CullingAggressiveness: String, Codable, CaseIterable, Sendable {
    case gentle
    case balanced
    case highlights

    public var displayName: String {
        switch self {
        case .gentle: "Gentle"
        case .balanced: "Balanced"
        case .highlights: "Highlights"
        }
    }
}

public enum ShortlistSizingMode: String, Codable, CaseIterable, Sendable {
    case count
    case percentage

    public var displayName: String {
        switch self {
        case .count: "Fixed count"
        case .percentage: "Percentage to keep"
        }
    }
}

public enum ShortlistEstimate {
    public static func resolvedTargetCount(
        totalPhotos: Int,
        sizingMode: ShortlistSizingMode,
        targetCount: Int,
        keepPercentage: Double
    ) -> Int {
        guard totalPhotos > 0 else { return max(1, targetCount) }
        switch sizingMode {
        case .count:
            return max(1, min(totalPhotos, targetCount))
        case .percentage:
            let percentage = min(max(keepPercentage, 1), 100)
            return max(1, min(totalPhotos, Int(round(Double(totalPhotos) * percentage / 100.0))))
        }
    }

    /// A rough range after duplicate grouping and culling aggressiveness are applied.
    public static func estimatedKeepRange(
        totalPhotos: Int,
        sizingMode: ShortlistSizingMode,
        targetCount: Int,
        keepPercentage: Double,
        aggressiveness: CullingAggressiveness
    ) -> ClosedRange<Int> {
        guard totalPhotos > 0 else { return 1...1 }
        let naive = Double(resolvedTargetCount(
            totalPhotos: totalPhotos,
            sizingMode: sizingMode,
            targetCount: targetCount,
            keepPercentage: keepPercentage
        ))
        let bounds: (Double, Double) = switch aggressiveness {
        case .gentle: (0.85, 1.0)
        case .balanced: (0.72, 0.92)
        case .highlights: (0.58, 0.82)
        }
        let low = max(1, Int(round(naive * bounds.0)))
        let high = max(low, min(totalPhotos, Int(round(naive * bounds.1))))
        return low...high
    }
}

public enum StylePreset: String, Codable, CaseIterable, Sendable {
    case natural
    case warm
    case vibrant
    case soft
    case blackAndWhite

    public var displayName: String {
        switch self {
        case .natural: "Natural"
        case .warm: "Warm"
        case .vibrant: "Vibrant"
        case .soft: "Soft"
        case .blackAndWhite: "Black & white"
        }
    }
}

public struct ScoringProfile: Codable, Sendable, Equatable {
    public var mode: CurationMode
    public var aggressiveness: CullingAggressiveness
    public var style: StylePreset
    public var styleIntensity: Double
    public var sizingMode: ShortlistSizingMode
    public var keepPercentage: Double
    public var sharpnessWeight: Double
    public var exposureWeight: Double
    public var faceWeight: Double
    public var aestheticWeight: Double
    public var diversityWeight: Double
    public var targetCount: Int
    public var burstWindow: TimeInterval
    /// Hard upper bound for a moment cluster. This prevents a long sequence of
    /// individually similar frames from becoming one unbounded burst.
    public var maxBurstDuration: TimeInterval
    public var nearDuplicateHammingDistance: Int
    public var nearDuplicateVisualDistance: Double
    /// Looser Vision distance for frames taken within `momentWindow` seconds of each other.
    /// A focus pull or a small reframe inside one second is still the same moment.
    public var momentVisualDistance: Double
    public var momentWindow: TimeInterval
    public var renderBase: RenderBase
    public var rejection: RejectionPolicy

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
        nearDuplicateVisualDistance: Double,
        momentVisualDistance: Double? = nil,
        momentWindow: TimeInterval = 3,
        renderBase: RenderBase = .raw,
        maxBurstDuration: TimeInterval? = nil,
        aggressiveness: CullingAggressiveness = .balanced,
        style: StylePreset = .natural,
        styleIntensity: Double = 0.65,
        sizingMode: ShortlistSizingMode = .count,
        keepPercentage: Double = 30,
        rejection: RejectionPolicy? = nil
    ) {
        self.mode = mode
        self.aggressiveness = aggressiveness
        self.style = style
        self.styleIntensity = styleIntensity
        self.sizingMode = sizingMode
        self.keepPercentage = keepPercentage
        self.sharpnessWeight = sharpnessWeight
        self.exposureWeight = exposureWeight
        self.faceWeight = faceWeight
        self.aestheticWeight = aestheticWeight
        self.diversityWeight = diversityWeight
        self.targetCount = targetCount
        self.burstWindow = burstWindow
        self.maxBurstDuration = maxBurstDuration ?? burstWindow * 4
        self.nearDuplicateHammingDistance = nearDuplicateHammingDistance
        self.nearDuplicateVisualDistance = nearDuplicateVisualDistance
        self.momentVisualDistance = momentVisualDistance ?? min(nearDuplicateVisualDistance + 0.12, 0.66)
        self.momentWindow = momentWindow
        self.renderBase = renderBase
        self.rejection = rejection ?? .default(for: mode)
    }

    public static func `default`(for mode: CurationMode) -> ScoringProfile {
        switch mode {
        case .everyday, .phoneDump:
            ScoringProfile(mode: mode, sharpnessWeight: 0.30, exposureWeight: 0.22, faceWeight: 0.20, aestheticWeight: 0.28, diversityWeight: 0.55, targetCount: 40, burstWindow: 12, nearDuplicateHammingDistance: 8, nearDuplicateVisualDistance: 0.50)
        case .groupEvent, .wedding, .family:
            ScoringProfile(mode: mode, sharpnessWeight: 0.22, exposureWeight: 0.14, faceWeight: 0.40, aestheticWeight: 0.24, diversityWeight: 0.70, targetCount: 50, burstWindow: 15, nearDuplicateHammingDistance: 9, nearDuplicateVisualDistance: 0.50)
        case .trip:
            ScoringProfile(mode: mode, sharpnessWeight: 0.24, exposureWeight: 0.18, faceWeight: 0.10, aestheticWeight: 0.48, diversityWeight: 0.82, targetCount: 60, burstWindow: 20, nearDuplicateHammingDistance: 8, nearDuplicateVisualDistance: 0.45)
        case .creative:
            ScoringProfile(mode: mode, sharpnessWeight: 0.12, exposureWeight: 0.10, faceWeight: 0.12, aestheticWeight: 0.66, diversityWeight: 0.90, targetCount: 60, burstWindow: 25, nearDuplicateHammingDistance: 10, nearDuplicateVisualDistance: 0.40)
        case .newborn:
            ScoringProfile(mode: mode, sharpnessWeight: 0.28, exposureWeight: 0.20, faceWeight: 0.22, aestheticWeight: 0.30, diversityWeight: 0.60, targetCount: 40, burstWindow: 18, nearDuplicateHammingDistance: 8, nearDuplicateVisualDistance: 0.50)
        case .sports:
            ScoringProfile(mode: mode, sharpnessWeight: 0.34, exposureWeight: 0.16, faceWeight: 0.18, aestheticWeight: 0.32, diversityWeight: 0.75, targetCount: 50, burstWindow: 8, nearDuplicateHammingDistance: 7, nearDuplicateVisualDistance: 0.55)
        }
    }

    public mutating func apply(aggressiveness: CullingAggressiveness) {
        self.aggressiveness = aggressiveness
        switch aggressiveness {
        case .gentle:
            nearDuplicateHammingDistance = max(nearDuplicateHammingDistance - 2, 3)
            nearDuplicateVisualDistance = max(nearDuplicateVisualDistance - 0.06, 0.25)
            momentVisualDistance = max(momentVisualDistance - 0.06, nearDuplicateVisualDistance)
            burstWindow *= 0.8
            maxBurstDuration *= 0.8
        case .balanced:
            break
        case .highlights:
            nearDuplicateHammingDistance += 2
            nearDuplicateVisualDistance = min(nearDuplicateVisualDistance + 0.05, 0.56)
            momentVisualDistance = min(momentVisualDistance + 0.05, 0.68)
            burstWindow *= 1.25
            maxBurstDuration *= 1.25
        }
        maxBurstDuration = max(maxBurstDuration, burstWindow)
    }

    public func resolvedTargetCount(for totalPhotos: Int) -> Int {
        ShortlistEstimate.resolvedTargetCount(
            totalPhotos: totalPhotos,
            sizingMode: sizingMode,
            targetCount: targetCount,
            keepPercentage: keepPercentage
        )
    }

    private enum CodingKeys: String, CodingKey {
        case mode, aggressiveness, style, styleIntensity, sizingMode, keepPercentage
        case sharpnessWeight, exposureWeight, faceWeight, aestheticWeight, diversityWeight
        case targetCount, burstWindow, maxBurstDuration
        case nearDuplicateHammingDistance, nearDuplicateVisualDistance, momentVisualDistance, momentWindow, renderBase
        case rejection
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        mode = try container.decode(CurationMode.self, forKey: .mode)
        aggressiveness = try container.decodeIfPresent(CullingAggressiveness.self, forKey: .aggressiveness) ?? .balanced
        style = try container.decodeIfPresent(StylePreset.self, forKey: .style) ?? .natural
        styleIntensity = try container.decodeIfPresent(Double.self, forKey: .styleIntensity) ?? 0.65
        sizingMode = try container.decodeIfPresent(ShortlistSizingMode.self, forKey: .sizingMode) ?? .count
        keepPercentage = try container.decodeIfPresent(Double.self, forKey: .keepPercentage) ?? 30
        sharpnessWeight = try container.decode(Double.self, forKey: .sharpnessWeight)
        exposureWeight = try container.decode(Double.self, forKey: .exposureWeight)
        faceWeight = try container.decode(Double.self, forKey: .faceWeight)
        aestheticWeight = try container.decode(Double.self, forKey: .aestheticWeight)
        diversityWeight = try container.decode(Double.self, forKey: .diversityWeight)
        targetCount = try container.decode(Int.self, forKey: .targetCount)
        burstWindow = try container.decode(TimeInterval.self, forKey: .burstWindow)
        maxBurstDuration = try container.decodeIfPresent(TimeInterval.self, forKey: .maxBurstDuration) ?? burstWindow * 4
        nearDuplicateHammingDistance = try container.decode(Int.self, forKey: .nearDuplicateHammingDistance)
        nearDuplicateVisualDistance = try container.decode(Double.self, forKey: .nearDuplicateVisualDistance)
        // Profiles written before Vision calibration stored 7…10, which is 15–20× the real scale.
        if nearDuplicateVisualDistance > 2 {
            nearDuplicateVisualDistance = ScoringProfile.default(for: mode).nearDuplicateVisualDistance
        }
        momentVisualDistance = try container.decodeIfPresent(Double.self, forKey: .momentVisualDistance)
            ?? min(nearDuplicateVisualDistance + 0.12, 0.66)
        momentWindow = try container.decodeIfPresent(TimeInterval.self, forKey: .momentWindow) ?? 3
        renderBase = try container.decodeIfPresent(RenderBase.self, forKey: .renderBase) ?? .raw
        rejection = try container.decodeIfPresent(RejectionPolicy.self, forKey: .rejection) ?? .default(for: mode)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(mode, forKey: .mode)
        try container.encode(aggressiveness, forKey: .aggressiveness)
        try container.encode(style, forKey: .style)
        try container.encode(styleIntensity, forKey: .styleIntensity)
        try container.encode(sizingMode, forKey: .sizingMode)
        try container.encode(keepPercentage, forKey: .keepPercentage)
        try container.encode(sharpnessWeight, forKey: .sharpnessWeight)
        try container.encode(exposureWeight, forKey: .exposureWeight)
        try container.encode(faceWeight, forKey: .faceWeight)
        try container.encode(aestheticWeight, forKey: .aestheticWeight)
        try container.encode(diversityWeight, forKey: .diversityWeight)
        try container.encode(targetCount, forKey: .targetCount)
        try container.encode(burstWindow, forKey: .burstWindow)
        try container.encode(maxBurstDuration, forKey: .maxBurstDuration)
        try container.encode(nearDuplicateHammingDistance, forKey: .nearDuplicateHammingDistance)
        try container.encode(nearDuplicateVisualDistance, forKey: .nearDuplicateVisualDistance)
        try container.encode(momentVisualDistance, forKey: .momentVisualDistance)
        try container.encode(momentWindow, forKey: .momentWindow)
        try container.encode(renderBase, forKey: .renderBase)
        try container.encode(rejection, forKey: .rejection)
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
    case protected
    case alternate
    case review
    case hidden
}

public enum CleanupPolicy: String, Codable, CaseIterable, Sendable {
    case preserveOriginals
    case keepSelectedOriginals
    case compactMemories

    public var displayName: String {
        switch self {
        case .preserveOriginals: "Preserve originals"
        case .keepSelectedOriginals: "Keep selected originals"
        case .compactMemories: "Compact memories"
        }
    }
}

public struct CleanupCandidate: Identifiable, Codable, Sendable, Equatable {
    public let id: UUID
    public let photoID: PhotoID
    public let sourcePath: String
    public let retainedPath: String
    public let contentHash: String
    public let bytes: Int64
    public let reason: String

    public init(
        id: UUID? = nil,
        photoID: PhotoID,
        sourcePath: String,
        retainedPath: String,
        contentHash: String,
        bytes: Int64,
        reason: String
    ) {
        self.id = id ?? photoID.rawValue
        self.photoID = photoID
        self.sourcePath = sourcePath
        self.retainedPath = retainedPath
        self.contentHash = contentHash
        self.bytes = bytes
        self.reason = reason
    }
}

public struct CleanupPlan: Identifiable, Codable, Sendable, Equatable {
    public let id: UUID
    public let sessionID: SessionID
    public let policy: CleanupPolicy
    public let createdAt: Date
    public let candidates: [CleanupCandidate]
    public let warnings: [String]

    public var estimatedBytes: Int64 {
        candidates.reduce(0) { $0 + $1.bytes }
    }

    public init(
        id: UUID = UUID(),
        sessionID: SessionID,
        policy: CleanupPolicy,
        createdAt: Date = Date(),
        candidates: [CleanupCandidate],
        warnings: [String] = []
    ) {
        self.id = id
        self.sessionID = sessionID
        self.policy = policy
        self.createdAt = createdAt
        self.candidates = candidates
        self.warnings = warnings
    }
}

public struct CleanupReport: Codable, Sendable, Equatable {
    public let planID: UUID
    public let movedPhotoIDs: [PhotoID]
    public let skipped: [String]

    public init(planID: UUID, movedPhotoIDs: [PhotoID], skipped: [String]) {
        self.planID = planID
        self.movedPhotoIDs = movedPhotoIDs
        self.skipped = skipped
    }
}

public enum ExportPreset: String, Codable, CaseIterable, Sendable {
    case full
    case compact

    public var displayName: String {
        switch self {
        case .full: "Full size"
        case .compact: "Compact"
        }
    }

    public var maxLongEdge: Int? {
        switch self {
        case .full: nil
        case .compact: 2048
        }
    }

    public var quality: Double {
        switch self {
        case .full: 0.92
        case .compact: 0.84
        }
    }
}

public struct ExportSpecification: Codable, Sendable, Equatable {
    public let preset: ExportPreset
    public let maxLongEdge: Int?
    public let quality: Double

    public init(preset: ExportPreset = .full, maxLongEdge: Int? = nil, quality: Double? = nil) {
        self.preset = preset
        self.maxLongEdge = maxLongEdge ?? preset.maxLongEdge
        self.quality = min(max(quality ?? preset.quality, 0.1), 1)
    }
}

public struct SelectionDecision: Identifiable, Codable, Sendable, Equatable {
    public let id: UUID
    public let photoID: PhotoID
    public let bucket: SelectionBucket
    public let rank: Int?
    public let reasons: [String]
    public let score: Double

    public init(id: UUID? = nil, photoID: PhotoID, bucket: SelectionBucket, rank: Int?, reasons: [String], score: Double) {
        // One photo can have only one automatic decision in a shortlist, so
        // using its stable asset identity keeps manifests and UI diffs
        // deterministic across repeated runs. Callers may still provide an
        // explicit ID for a separately tracked manual event.
        self.id = id ?? photoID.rawValue
        self.photoID = photoID
        self.bucket = bucket
        self.rank = rank
        self.reasons = reasons
        self.score = score
    }
}

public struct SelectionOverride: Codable, Sendable, Equatable {
    public let photoID: PhotoID
    public let bucket: SelectionBucket
    public let reason: String

    public init(photoID: PhotoID, bucket: SelectionBucket, reason: String = "user override") {
        self.photoID = photoID
        self.bucket = bucket
        self.reason = reason
    }
}

public struct Shortlist: Codable, Sendable, Equatable {
    public var decisions: [SelectionDecision]
    public var selectedIDs: [PhotoID] {
        decisions
            .filter { $0.bucket == .selected || $0.bucket == .protected }
            .sorted { ($0.rank ?? .max) < ($1.rank ?? .max) }
            .map(\.photoID)
    }

    public init(decisions: [SelectionDecision]) {
        self.decisions = decisions
    }
}

public enum RenderBase: String, Codable, Sendable, CaseIterable {
    /// Decode the RAW master with Core Image (falls back to the file itself for non-RAW).
    case raw
    /// Start from the camera's own JPEG shot alongside the RAW, when one exists.
    case cameraJPEG
}

/// Quiet portrait finishing. Strengths are 0…1.
public struct RetouchSettings: Codable, Sendable, Equatable {
    public var skinSmooth: Double
    public var eyesBrighten: Double
    public var teethWhiten: Double
    public var flyawayReduce: Double
    public var clarityLift: Double

    public static let off = RetouchSettings(skinSmooth: 0, eyesBrighten: 0, teethWhiten: 0, flyawayReduce: 0, clarityLift: 0)
    public static let wedding = RetouchSettings(skinSmooth: 0.35, eyesBrighten: 0.2, teethWhiten: 0.15, flyawayReduce: 0.2, clarityLift: 0.08)

    public init(
        skinSmooth: Double = 0,
        eyesBrighten: Double = 0,
        teethWhiten: Double = 0,
        flyawayReduce: Double = 0,
        clarityLift: Double = 0
    ) {
        self.skinSmooth = skinSmooth
        self.eyesBrighten = eyesBrighten
        self.teethWhiten = teethWhiten
        self.flyawayReduce = flyawayReduce
        self.clarityLift = clarityLift
    }

    public var isActive: Bool {
        skinSmooth > 0.01 || eyesBrighten > 0.01 || teethWhiten > 0.01 || flyawayReduce > 0.01 || clarityLift > 0.01
    }
}

public struct EditRecipe: Codable, Sendable, Equatable {
    public var style: StylePreset
    public var styleIntensity: Double
    public var exposure: Double
    public var contrast: Double
    public var saturation: Double
    public var highlights: Double
    public var shadows: Double
    public var sharpening: Double
    /// -1 cools, +1 warms, on top of any look.
    public var temperature: Double
    /// -1 green, +1 magenta.
    public var tint: Double
    /// Midtone local contrast. Negative softens.
    public var clarity: Double
    /// Degrees. Positive rotates clockwise in the preview.
    public var straighten: Double
    /// Optional imported look (LUT / XMP preset) applied after the base recipe.
    public var albumLookID: String?
    /// Apple's automatic tone, color, and face adjustments, applied before the look.
    public var autoEnhance: Bool
    /// RAW decode versus the camera JPEG shot alongside the RAW.
    public var base: RenderBase
    public var retouch: RetouchSettings

    public init(
        style: StylePreset = .natural,
        styleIntensity: Double = 0.65,
        exposure: Double = 0,
        contrast: Double = 0,
        saturation: Double = 0,
        highlights: Double = 0,
        shadows: Double = 0,
        sharpening: Double = 0,
        temperature: Double = 0,
        tint: Double = 0,
        clarity: Double = 0,
        straighten: Double = 0,
        albumLookID: String? = nil,
        autoEnhance: Bool = false,
        base: RenderBase = .raw,
        retouch: RetouchSettings = .off
    ) {
        self.style = style
        self.styleIntensity = styleIntensity
        self.exposure = exposure
        self.contrast = contrast
        self.saturation = saturation
        self.highlights = highlights
        self.shadows = shadows
        self.sharpening = sharpening
        self.temperature = temperature
        self.tint = tint
        self.clarity = clarity
        self.straighten = straighten
        self.albumLookID = albumLookID
        self.autoEnhance = autoEnhance
        self.base = base
        self.retouch = retouch
    }

    private enum CodingKeys: String, CodingKey {
        case style, styleIntensity, exposure, contrast, saturation, highlights, shadows, sharpening
        case temperature, tint, clarity, straighten, albumLookID, autoEnhance, base, retouch
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        style = try container.decode(StylePreset.self, forKey: .style)
        styleIntensity = try container.decode(Double.self, forKey: .styleIntensity)
        exposure = try container.decode(Double.self, forKey: .exposure)
        contrast = try container.decode(Double.self, forKey: .contrast)
        saturation = try container.decode(Double.self, forKey: .saturation)
        highlights = try container.decode(Double.self, forKey: .highlights)
        shadows = try container.decode(Double.self, forKey: .shadows)
        sharpening = try container.decode(Double.self, forKey: .sharpening)
        temperature = try container.decodeIfPresent(Double.self, forKey: .temperature) ?? 0
        tint = try container.decodeIfPresent(Double.self, forKey: .tint) ?? 0
        clarity = try container.decodeIfPresent(Double.self, forKey: .clarity) ?? 0
        straighten = try container.decodeIfPresent(Double.self, forKey: .straighten) ?? 0
        albumLookID = try container.decodeIfPresent(String.self, forKey: .albumLookID)
        autoEnhance = try container.decodeIfPresent(Bool.self, forKey: .autoEnhance) ?? false
        base = try container.decodeIfPresent(RenderBase.self, forKey: .base) ?? .raw
        retouch = try container.decodeIfPresent(RetouchSettings.self, forKey: .retouch) ?? .off
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(style, forKey: .style)
        try container.encode(styleIntensity, forKey: .styleIntensity)
        try container.encode(exposure, forKey: .exposure)
        try container.encode(contrast, forKey: .contrast)
        try container.encode(saturation, forKey: .saturation)
        try container.encode(highlights, forKey: .highlights)
        try container.encode(shadows, forKey: .shadows)
        try container.encode(sharpening, forKey: .sharpening)
        try container.encode(temperature, forKey: .temperature)
        try container.encode(tint, forKey: .tint)
        try container.encode(clarity, forKey: .clarity)
        try container.encode(straighten, forKey: .straighten)
        try container.encodeIfPresent(albumLookID, forKey: .albumLookID)
        try container.encode(autoEnhance, forKey: .autoEnhance)
        try container.encode(base, forKey: .base)
        try container.encode(retouch, forKey: .retouch)
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
    public let sessionID: SessionID
    public let schemaVersion: Int
    public let pipelineVersion: String
    public let createdAt: Date
    public let sourceFolder: String
    public let mode: CurationMode
    public let profile: ScoringProfile
    public let aggressiveness: CullingAggressiveness
    public let style: StylePreset
    public let styleIntensity: Double
    public let targetCount: Int
    public let exportSpecification: ExportSpecification
    public let assets: [PhotoAsset]
    public let analyzed: [AnalyzedPhoto]
    public let grouping: PhotoGrouping
    public let shortlist: Shortlist
    public let exports: [ExportedPhoto]
    public let warnings: [String]
    public let metrics: PipelineMetrics

    public init(
        sessionID: SessionID = SessionID(),
        schemaVersion: Int = 3,
        pipelineVersion: String = "0.3.0",
        createdAt: Date = Date(),
        sourceFolder: String,
        mode: CurationMode,
        profile: ScoringProfile? = nil,
        aggressiveness: CullingAggressiveness = .balanced,
        style: StylePreset = .natural,
        styleIntensity: Double = 0.65,
        targetCount: Int = 0,
        exportSpecification: ExportSpecification = ExportSpecification(),
        assets: [PhotoAsset],
        analyzed: [AnalyzedPhoto],
        grouping: PhotoGrouping,
        shortlist: Shortlist,
        exports: [ExportedPhoto],
        warnings: [String] = [],
        metrics: PipelineMetrics = PipelineMetrics()
    ) {
        self.sessionID = sessionID
        self.schemaVersion = schemaVersion
        self.pipelineVersion = pipelineVersion
        self.createdAt = createdAt
        self.sourceFolder = sourceFolder
        self.mode = mode
        self.profile = profile ?? ScoringProfile.default(for: mode)
        self.aggressiveness = aggressiveness
        self.style = style
        self.styleIntensity = styleIntensity
        self.targetCount = targetCount
        self.exportSpecification = exportSpecification
        self.assets = assets
        self.analyzed = analyzed
        self.grouping = grouping
        self.shortlist = shortlist
        self.exports = exports
        self.warnings = warnings
        self.metrics = metrics
    }

    private enum CodingKeys: String, CodingKey {
        case sessionID, schemaVersion, pipelineVersion, createdAt, sourceFolder,
             mode, aggressiveness, style, styleIntensity, targetCount, assets,
             profile, analyzed, grouping, shortlist, exports, warnings, metrics,
             exportSpecification
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sessionID = try container.decodeIfPresent(SessionID.self, forKey: .sessionID) ?? SessionID()
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        pipelineVersion = try container.decodeIfPresent(String.self, forKey: .pipelineVersion) ?? "0.1.0"
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date.distantPast
        sourceFolder = try container.decode(String.self, forKey: .sourceFolder)
        mode = try container.decodeIfPresent(CurationMode.self, forKey: .mode) ?? .everyday
        profile = try container.decodeIfPresent(ScoringProfile.self, forKey: .profile) ?? ScoringProfile.default(for: mode)
        aggressiveness = try container.decodeIfPresent(CullingAggressiveness.self, forKey: .aggressiveness) ?? .balanced
        style = try container.decodeIfPresent(StylePreset.self, forKey: .style) ?? .natural
        styleIntensity = try container.decodeIfPresent(Double.self, forKey: .styleIntensity) ?? 0.65
        targetCount = try container.decodeIfPresent(Int.self, forKey: .targetCount) ?? 0
        exportSpecification = try container.decodeIfPresent(ExportSpecification.self, forKey: .exportSpecification) ?? ExportSpecification()
        assets = try container.decodeIfPresent([PhotoAsset].self, forKey: .assets) ?? []
        analyzed = try container.decodeIfPresent([AnalyzedPhoto].self, forKey: .analyzed) ?? []
        grouping = try container.decodeIfPresent(PhotoGrouping.self, forKey: .grouping) ?? PhotoGrouping(groups: [])
        shortlist = try container.decodeIfPresent(Shortlist.self, forKey: .shortlist) ?? Shortlist(decisions: [])
        exports = try container.decodeIfPresent([ExportedPhoto].self, forKey: .exports) ?? []
        warnings = try container.decodeIfPresent([String].self, forKey: .warnings) ?? []
        metrics = try container.decodeIfPresent(PipelineMetrics.self, forKey: .metrics) ?? PipelineMetrics()
    }
}

/// Lightweight local diagnostics included in a manifest so performance claims
/// can be measured on real libraries without uploading telemetry.
public struct PipelineMetrics: Codable, Sendable, Equatable {
    public let totalSeconds: Double
    public let discoverySeconds: Double
    public let analysisSeconds: Double
    public let groupingSeconds: Double
    public let selectionSeconds: Double
    public let exportSeconds: Double
    public let cacheHits: Int
    public let exactContentReuses: Int
    public let analyzedCount: Int
    public let workerCount: Int

    public init(
        totalSeconds: Double = 0,
        discoverySeconds: Double = 0,
        analysisSeconds: Double = 0,
        groupingSeconds: Double = 0,
        selectionSeconds: Double = 0,
        exportSeconds: Double = 0,
        cacheHits: Int = 0,
        exactContentReuses: Int = 0,
        analyzedCount: Int = 0,
        workerCount: Int = 1
    ) {
        self.totalSeconds = totalSeconds
        self.discoverySeconds = discoverySeconds
        self.analysisSeconds = analysisSeconds
        self.groupingSeconds = groupingSeconds
        self.selectionSeconds = selectionSeconds
        self.exportSeconds = exportSeconds
        self.cacheHits = cacheHits
        self.exactContentReuses = exactContentReuses
        self.analyzedCount = analyzedCount
        self.workerCount = workerCount
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

    public var errorDescription: String? {
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

public enum PhotoFocusRanking {
    /// Rewrites `sharpness` as the photo's focus percentile within this shoot (0.15…1),
    /// using `focusEnergy`. Absolute Laplacian values vary by camera, lens and scene;
    /// the ranking is what matters for picking the best frame of a moment.
    /// Leaves photos untouched when fewer than 8 have a focus measurement.
    public static func apply(to photos: [AnalyzedPhoto]) -> [AnalyzedPhoto] {
        let energies = photos.compactMap(\.signals.focusEnergy).sorted()
        guard energies.count >= 8 else { return photos }
        let denominator = Double(energies.count - 1)
        return photos.map { photo in
            guard let energy = photo.signals.focusEnergy else { return photo }
            let rank = Double(energies.firstIndex { $0 >= energy } ?? energies.count - 1)
            var signals = photo.signals
            signals.sharpness = 0.15 + 0.85 * (rank / denominator)
            return AnalyzedPhoto(asset: photo.asset, signals: signals)
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
        var face = signals.faceCount == 0 ? 0.5 : signals.faceQuality
        if profile.rejection.facesMatter, let openness = averageEyeOpenness(signals), signals.faceCount > 0 {
            face = face * 0.55 + openness * 0.45
        }
        let sharpness = signals.faceCount > 0 && signals.subjectSharpness != nil
            ? (signals.subjectSharpness! * 0.70 + signals.sharpness * 0.30)
            : signals.sharpness
        var total =
            sharpness * profile.sharpnessWeight +
            signals.exposureQuality * profile.exposureWeight +
            face * profile.faceWeight +
            aesthetic * profile.aestheticWeight
        if profile.rejection.closedEyesMatter, signals.qualityFlags.contains(PhotoTechnicalReject.eyesClosed) {
            total *= 0.42
        }

        var reasons: [String] = []
        if sharpness >= 0.65 { reasons.append("sharp") }
        if signals.qualityFlags.contains("subject appears soft") { reasons.append("subject appears soft") }
        if signals.qualityFlags.contains(PhotoTechnicalReject.eyesClosed) { reasons.append("eyes appear closed") }
        if signals.exposureQuality >= 0.65 { reasons.append("well exposed") }
        if signals.faceCount > 0 && face >= 0.65 { reasons.append("strong faces") }
        if let openness = averageEyeOpenness(signals), openness >= 0.72, signals.faceCount > 0 {
            reasons.append("eyes open")
        }
        if aesthetic >= 0.65 { reasons.append("aesthetic") }
        if reasons.isEmpty { reasons.append("best available candidate") }

        return CompositeScore(
            total: min(max(total, 0), 1),
            components: [
                "sharpness": sharpness,
                "subjectSharpness": signals.subjectSharpness ?? signals.sharpness,
                "exposure": signals.exposureQuality,
                "faceQuality": face,
                "aesthetic": aesthetic
            ],
            reasons: reasons
        )
    }

    private static func averageEyeOpenness(_ signals: AnalysisSignals) -> Double? {
        let values = signals.faces.compactMap(\.eyeOpenness)
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
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
        let firstDate: Date?
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
                clusters.append(WorkingCluster(units: [unit], representativeIndex: unit.representativeIndex, firstDate: nil, latestDate: nil))
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
                guard let firstDate = clusters[clusterIndex].firstDate,
                      date.timeIntervalSince(firstDate) <= profile.maxBurstDuration else { continue }
                compared += 1

                let left = photos[unit.representativeIndex]
                let right = photos[clusters[clusterIndex].representativeIndex]
                let close: Bool
                if let visionDistance = visualDistance(left.signals, right.signals) {
                    // Vision is the evidence. Measured on real shoots: the same shot
                    // repeated is ≤ ~0.5; unrelated photos start at ~0.58.
                    let threshold = abs(interval) <= profile.momentWindow
                        ? profile.momentVisualDistance
                        : profile.nearDuplicateVisualDistance
                    close = visionDistance <= threshold
                } else {
                    // No feature print (older cache entries, fixtures): fall back to the hash.
                    let hamming = PhotoSimilarity.hammingDistance(
                        left.signals.fingerprint.perceptualHash,
                        right.signals.fingerprint.perceptualHash
                    )
                    close = hamming <= profile.nearDuplicateHammingDistance
                }
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
                clusters.append(WorkingCluster(units: [unit], representativeIndex: unit.representativeIndex, firstDate: date, latestDate: date))
            }
        }

        let groups = clusters.compactMap { cluster -> PhotoGroup? in
            let indices = cluster.units.flatMap(\.memberIndices)
            guard indices.count > 1 else { return nil }
            let kind: PhotoGroup.Kind = cluster.units.count == 1 ? .exactDuplicate : .burst
            let memberIDs = indices.map { photos[$0].id }
            return PhotoGroup(id: memberIDs[0].rawValue, memberIDs: memberIDs, kind: kind)
        }
        return PhotoGrouping(groups: groups.sorted {
            let left = $0.memberIDs.first?.description ?? ""
            let right = $1.memberIDs.first?.description ?? ""
            return left < right
        })
    }
}

public enum SelectionReason {
    public static let justBelowCut = "just below the cut"
    public static let belowCut = "weaker than the shortlist"
    public static let sameMomentAsKept = "same moment as a photo we kept"
    public static let nearDuplicate = "near-duplicate of a stronger candidate"
    public static let exactDuplicate = "exact duplicate of a stronger candidate"
}

public enum PhotoSelectionEngine {
    public static func applying(_ overrides: [SelectionOverride], to shortlist: Shortlist) -> Shortlist {
        guard !overrides.isEmpty else { return shortlist }
        let byID = Dictionary(uniqueKeysWithValues: overrides.map { ($0.photoID, $0) })
        let decisions = shortlist.decisions.map { decision -> SelectionDecision in
            guard let override = byID[decision.photoID] else { return decision }
            let rank = override.bucket == .selected || override.bucket == .protected ? decision.rank : nil
            return SelectionDecision(
                id: decision.id,
                photoID: decision.photoID,
                bucket: override.bucket,
                rank: rank,
                reasons: [override.reason] + decision.reasons,
                score: decision.score
            )
        }
        return Shortlist(decisions: decisions)
    }

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
        var trashIDs = Set<PhotoID>()

        for photo in photos {
            guard let reason = PhotoTechnicalReject.reason(for: photo.photo.signals, policy: profile.rejection) else { continue }
            trashIDs.insert(photo.id)
            decisions.append(SelectionDecision(
                photoID: photo.id,
                bucket: .hidden,
                rank: nil,
                reasons: [reason],
                score: photo.score.total
            ))
        }

        for group in grouping.groups {
            let members = group.memberIDs.compactMap { byID[$0] }
            let usable = members.filter { !trashIDs.contains($0.id) }
            groupedIDs.formUnion(group.memberIDs)
            guard !usable.isEmpty else { continue }

            let contentBuckets = Dictionary(grouping: usable) {
                $0.photo.signals.fingerprint.contentHash
            }
            let orderedBuckets = contentBuckets.keys.sorted().compactMap { contentBuckets[$0] }
            let bucketRepresentatives = orderedBuckets.compactMap { bucket in
                bucket.max { lhs, rhs in Self.isPreferred(rhs, over: lhs) }
            }
            guard let best = bucketRepresentatives.max(by: { Self.isPreferred($1, over: $0) }) else { continue }
            candidates.append(best)

            for bucketMembers in orderedBuckets {
                let ordered = bucketMembers.sorted { Self.isPreferred($0, over: $1) }
                guard let representative = ordered.first else { continue }
                if representative.id != best.id {
                    decisions.append(SelectionDecision(
                        photoID: representative.id,
                        bucket: .alternate,
                        rank: nil,
                        reasons: [SelectionReason.nearDuplicate],
                        score: representative.score.total
                    ))
                }
                for duplicate in ordered.dropFirst() {
                    decisions.append(SelectionDecision(
                        photoID: duplicate.id,
                        bucket: .hidden,
                        rank: nil,
                        reasons: [SelectionReason.exactDuplicate],
                        score: duplicate.score.total
                    ))
                }
            }
        }

        candidates.append(contentsOf: photos.filter { !groupedIDs.contains($0.id) && !trashIDs.contains($0.id) })
        candidates.sort { Self.isPreferred($0, over: $1) }

        var selected: [ScoredPhoto] = []
        var redundantDecisions: [SelectionDecision] = []
        var remaining = candidates
        var maximumSimilarity: [PhotoID: Double] = [:]
        while selected.count < profile.targetCount, !remaining.isEmpty {
            var bestIndex = 0
            var bestValue = -Double.infinity
            for (index, candidate) in remaining.enumerated() {
                let redundancy = maximumSimilarity[candidate.id] ?? 0
                let value = candidate.score.total - profile.diversityWeight * redundancy
                if value > bestValue || (value == bestValue && Self.isPreferred(candidate, over: remaining[bestIndex])) {
                    bestValue = value
                    bestIndex = index
                }
            }
            let chosen = remaining.remove(at: bestIndex)
            selected.append(chosen)
            var sameMomentIDs = Set<PhotoID>()
            let chosenDate = chosen.photo.asset.metadata.captureDate
            // Hard "same moment" removal needs time corroboration. Venue-homogeneous
            // shoots (mats, stages, travel days) often sit under the visual near-dup
            // threshold even across unrelated minutes; soft diversity still applies.
            let momentWindow = max(profile.burstWindow, profile.maxBurstDuration)
            for candidate in remaining {
                let similarity: Double
                var hardSameMoment = false
                if let distance = visualDistance(candidate.photo.signals, chosen.photo.signals) {
                    // Distances are on Vision's calibrated scale (~0.3 same shot, ~1.0 unrelated).
                    similarity = exp(-distance / max(profile.nearDuplicateVisualDistance, 0.001))
                    if distance <= profile.nearDuplicateVisualDistance {
                        if let chosenDate, let candidateDate = candidate.photo.asset.metadata.captureDate {
                            hardSameMoment = abs(candidateDate.timeIntervalSince(chosenDate)) <= momentWindow
                        } else {
                            // No timestamps: require a tighter visual match before hard-removing.
                            hardSameMoment = distance <= profile.nearDuplicateVisualDistance * 0.65
                        }
                    }
                } else {
                    let hamming = PhotoSimilarity.hammingDistance(
                        candidate.photo.signals.fingerprint.perceptualHash,
                        chosen.photo.signals.fingerprint.perceptualHash
                    )
                    similarity = 1 - PhotoSimilarity.normalizedHammingDistance(
                        candidate.photo.signals.fingerprint.perceptualHash,
                        chosen.photo.signals.fingerprint.perceptualHash
                    )
                    if hamming <= profile.nearDuplicateHammingDistance {
                        if let chosenDate, let candidateDate = candidate.photo.asset.metadata.captureDate {
                            hardSameMoment = abs(candidateDate.timeIntervalSince(chosenDate)) <= momentWindow
                        } else {
                            hardSameMoment = hamming <= max(3, profile.nearDuplicateHammingDistance / 2)
                        }
                    }
                }
                maximumSimilarity[candidate.id] = max(maximumSimilarity[candidate.id] ?? 0, similarity)
                if hardSameMoment { sameMomentIDs.insert(candidate.id) }
            }
            if !sameMomentIDs.isEmpty {
                for candidate in remaining where sameMomentIDs.contains(candidate.id) {
                    redundantDecisions.append(SelectionDecision(
                        photoID: candidate.id,
                        bucket: .alternate,
                        rank: nil,
                        reasons: [SelectionReason.sameMomentAsKept],
                        score: candidate.score.total
                    ))
                }
                remaining.removeAll { sameMomentIDs.contains($0.id) }
            }
        }
        decisions.append(contentsOf: redundantDecisions)

        for (rank, photo) in selected.enumerated() {
            decisions.append(SelectionDecision(photoID: photo.id, bucket: .selected, rank: rank, reasons: photo.score.reasons, score: photo.score.total))
        }

        let cutoff = selected.last?.score.total ?? 0
        // Only a handful of genuinely borderline photos go to review; the rest are hidden.
        let reviewLimit = max(3, selected.count / 10)
        var reviewCount = 0
        for photo in remaining.sorted(by: { Self.isPreferred($0, over: $1) }) {
            let borderline = cutoff - photo.score.total < 0.03 && reviewCount < reviewLimit
            if borderline { reviewCount += 1 }
            decisions.append(SelectionDecision(
                photoID: photo.id,
                bucket: borderline ? .review : .hidden,
                rank: nil,
                reasons: [borderline ? SelectionReason.justBelowCut : SelectionReason.belowCut],
                score: photo.score.total
            ))
        }

        return Shortlist(decisions: decisions)
    }

    private static func isPreferred(_ lhs: ScoredPhoto, over rhs: ScoredPhoto) -> Bool {
        if lhs.score.total != rhs.score.total { return lhs.score.total > rhs.score.total }
        return lhs.id.description < rhs.id.description
    }
}

public enum ReviewFlag: String, Codable, Sendable, CaseIterable {
    case unflagged
    case pick
    case reject
}

public enum ReviewColor: String, Codable, Sendable, CaseIterable {
    case none
    case red
    case yellow
    case green
    case blue
    case purple

    /// Lightroom color labels are proper-case English names.
    public var lightroomLabel: String? {
        switch self {
        case .none: nil
        case .red: "Red"
        case .yellow: "Yellow"
        case .green: "Green"
        case .blue: "Blue"
        case .purple: "Purple"
        }
    }
}

/// A photographer's mark, stored separately from the automatic culling bucket.
/// Stars and color labels match the Lightroom vocabulary. Pick and reject are
/// the cull flags; Lightroom does not keep those flags in XMP, so sidecars
/// also emit them as keywords.
public struct PhotoReviewMark: Codable, Sendable, Equatable {
    public var photoID: PhotoID
    public var flag: ReviewFlag
    public var stars: Int
    public var color: ReviewColor

    public init(photoID: PhotoID, flag: ReviewFlag = .unflagged, stars: Int = 0, color: ReviewColor = .none) {
        self.photoID = photoID
        self.flag = flag
        self.stars = min(5, max(0, stars))
        self.color = color
    }
}

public struct PortableCullEntry: Codable, Sendable, Equatable {
    public var fileName: String
    public var relativePath: String
    public var bucket: String
    public var flag: String
    public var stars: Int
    public var color: String
    public var reasons: [String]

    public init(fileName: String, relativePath: String, bucket: String, flag: String, stars: Int, color: String, reasons: [String]) {
        self.fileName = fileName
        self.relativePath = relativePath
        self.bucket = bucket
        self.flag = flag
        self.stars = stars
        self.color = color
        self.reasons = reasons
    }
}

public enum LightroomSidecar {
    public static func document(for mark: PhotoReviewMark) -> String {
        let stars = min(5, max(0, mark.stars))
        var attributes = [
            "xmlns:xmp=\"http://ns.adobe.com/xap/1.0/\"",
            "xmlns:dc=\"http://purl.org/dc/elements/1.1/\"",
            "xmlns:photocore=\"urn:photocore:ns:1.0\"",
            "xmp:Rating=\"\(stars)\"",
            "photocore:Flag=\"\(mark.flag.rawValue)\""
        ]
        if let label = mark.color.lightroomLabel {
            attributes.append("xmp:Label=\"\(label)\"")
        }
        let keywords = keywordItems(for: mark.flag)
        return """
        <?xpacket begin="\u{FEFF}" id="W5M0MpCehiHzreSzNTczkc9d"?>
        <x:xmpmeta xmlns:x="adobe:ns:meta/" x:xmptk="Photocore 0.4">
         <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
          <rdf:Description rdf:about=""
           \(attributes.joined(separator: "\n           "))>
        \(keywords)
          </rdf:Description>
         </rdf:RDF>
        </x:xmpmeta>
        <?xpacket end="w"?>
        """
    }

    public enum WriteOutcome: Sendable, Equatable {
        case written(URL)
        case skippedExistingSidecar(URL)
    }

    public static func sidecarURL(named baseName: String, in directory: URL) throws -> URL {
        let sanitized = baseName
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        guard !sanitized.isEmpty, sanitized != ".", sanitized != ".." else {
            throw PhotoEngineError.invalidArgument("Sidecar name is empty.")
        }
        return directory.appendingPathComponent(sanitized).appendingPathExtension("xmp")
    }

    /// True only for sidecars Photocore wrote. Anything else (Lightroom, Camera Raw,
    /// Capture One) belongs to the photographer.
    public static func isPhotocoreSidecar(at url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) else { return false }
        return text.contains("x:xmptk=\"Photocore") && text.contains("urn:photocore:ns:1.0")
    }

    public static func write(_ mark: PhotoReviewMark, named baseName: String, to directory: URL) throws -> URL {
        let url = try sidecarURL(named: baseName, in: directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(document(for: mark).utf8).write(to: url, options: .atomic)
        return url
    }

    /// Writes a sidecar unless a sidecar Photocore did not write is already there.
    /// Lightroom and Camera Raw keep develop settings in that file; replacing it destroys edits.
    public static func writePreservingExisting(_ mark: PhotoReviewMark, named baseName: String, to directory: URL) throws -> WriteOutcome {
        let url = try sidecarURL(named: baseName, in: directory)
        if FileManager.default.fileExists(atPath: url.path), !isPhotocoreSidecar(at: url) {
            return .skippedExistingSidecar(url)
        }
        return .written(try write(mark, named: baseName, to: directory))
    }

    public static func decisionsData(_ entries: [PortableCullEntry]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(entries)
    }

    private static func keywordItems(for flag: ReviewFlag) -> String {
        let keyword: String? = switch flag {
        case .pick: "Photocore Pick"
        case .reject: "Photocore Reject"
        case .unflagged: nil
        }
        guard let keyword else { return "" }
        return """
               <dc:subject>
                <rdf:Bag>
                 <rdf:li>\(keyword)</rdf:li>
                </rdf:Bag>
               </dc:subject>
        """
    }
}
