import Foundation

/// Learned cull preferences from a photographer's picks and rejects.
/// Applied as soft score biases — never overrides hard technical rejects.
public struct TasteProfile: Codable, Sendable, Equatable {
    public var sampleCount: Int
    public var pickCount: Int
    public var rejectCount: Int
    /// Preferred sharpness relative to shoot median (−1…1 learned bias).
    public var sharpnessBias: Double
    public var faceQualityBias: Double
    public var eyeOpenBias: Double
    public var exposureBias: Double
    /// How aggressively to drop near-duplicates (0…1). Higher = fewer similar keeps.
    public var diversityBias: Double
    /// Preferred keep density as a fraction of source count when learned.
    public var preferredKeepFraction: Double?
    public var updatedAt: Date

    public static let empty = TasteProfile(
        sampleCount: 0,
        pickCount: 0,
        rejectCount: 0,
        sharpnessBias: 0,
        faceQualityBias: 0,
        eyeOpenBias: 0,
        exposureBias: 0,
        diversityBias: 0,
        preferredKeepFraction: nil,
        updatedAt: .distantPast
    )

    public init(
        sampleCount: Int,
        pickCount: Int,
        rejectCount: Int,
        sharpnessBias: Double,
        faceQualityBias: Double,
        eyeOpenBias: Double,
        exposureBias: Double,
        diversityBias: Double,
        preferredKeepFraction: Double?,
        updatedAt: Date
    ) {
        self.sampleCount = sampleCount
        self.pickCount = pickCount
        self.rejectCount = rejectCount
        self.sharpnessBias = sharpnessBias
        self.faceQualityBias = faceQualityBias
        self.eyeOpenBias = eyeOpenBias
        self.exposureBias = exposureBias
        self.diversityBias = diversityBias
        self.preferredKeepFraction = preferredKeepFraction
        self.updatedAt = updatedAt
    }

    public var isReady: Bool { sampleCount >= 12 }

    /// Soft additive adjustment for a scored photo (−0.12…0.12).
    public func scoreAdjustment(signals: AnalysisSignals) -> Double {
        guard isReady else { return 0 }
        var delta = 0.0
        delta += sharpnessBias * (signals.sharpness - 0.5) * 0.18
        delta += faceQualityBias * (signals.faceQuality - 0.5) * 0.16
        let eyeValues = signals.faces.compactMap(\.eyeOpenness)
        if !eyeValues.isEmpty {
            let eyes = eyeValues.reduce(0, +) / Double(eyeValues.count)
            delta += eyeOpenBias * (eyes - 0.5) * 0.14
        }
        delta += exposureBias * (signals.exposureQuality - 0.5) * 0.12
        return min(0.12, max(-0.12, delta))
    }

    public func diversityWeight(base: Double) -> Double {
        guard isReady else { return base }
        return min(1.2, max(0.15, base + diversityBias * 0.35))
    }
}

public enum TasteMemory {
    private static let fileName = "taste-profile.json"

    public static var storeURL: URL {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let dir = root.appendingPathComponent("Photocore", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(fileName)
    }

    public static func load() -> TasteProfile {
        guard let data = try? Data(contentsOf: storeURL),
              let profile = try? JSONDecoder().decode(TasteProfile.self, from: data) else {
            return .empty
        }
        return profile
    }

    public static func save(_ profile: TasteProfile) throws {
        let data = try JSONEncoder().encode(profile)
        try data.write(to: storeURL, options: .atomic)
    }

    /// Incorporate one shoot's marks into the running profile.
    public static func learn(
        from marks: [PhotoReviewMark],
        analyzed: [AnalyzedPhoto],
        keptCount: Int,
        sourceCount: Int,
        existing: TasteProfile = load()
    ) -> TasteProfile {
        let byID = Dictionary(uniqueKeysWithValues: analyzed.map { ($0.id, $0) })
        let picks = marks.filter { $0.flag == .pick || $0.stars >= 4 }.compactMap { byID[$0.photoID] }
        let rejects = marks.filter { $0.flag == .reject }.compactMap { byID[$0.photoID] }
        guard picks.count + rejects.count >= 3 else { return existing }

        func mean(_ values: [Double]) -> Double {
            guard !values.isEmpty else { return 0.5 }
            return values.reduce(0, +) / Double(values.count)
        }

        let pickSharp = mean(picks.map(\.signals.sharpness))
        let rejectSharp = mean(rejects.map(\.signals.sharpness))
        let pickFace = mean(picks.map(\.signals.faceQuality))
        let rejectFace = mean(rejects.map(\.signals.faceQuality))
        func eyeMean(_ photos: [AnalyzedPhoto]) -> Double {
            mean(photos.compactMap { photo -> Double? in
                let values = photo.signals.faces.compactMap(\.eyeOpenness)
                guard !values.isEmpty else { return nil }
                return values.reduce(0, +) / Double(values.count)
            })
        }
        let pickEyes = eyeMean(picks)
        let rejectEyes = eyeMean(rejects)
        let pickExp = mean(picks.map(\.signals.exposureQuality))
        let rejectExp = mean(rejects.map(\.signals.exposureQuality))

        let alpha = min(0.45, 0.12 + Double(picks.count + rejects.count) * 0.02)
        func blend(_ old: Double, _ signal: Double) -> Double {
            old * (1 - alpha) + signal * alpha
        }

        let sharpSignal = min(1, max(-1, (pickSharp - rejectSharp) * 2))
        let faceSignal = min(1, max(-1, (pickFace - rejectFace) * 2))
        let eyeSignal = min(1, max(-1, (pickEyes - rejectEyes) * 2))
        let expSignal = min(1, max(-1, (pickExp - rejectExp) * 2))
        // More rejects of near-dup alternates → want more diversity.
        let diversitySignal = min(1, max(-1, Double(rejects.count - picks.count) / 20))

        var keepFraction = existing.preferredKeepFraction
        if sourceCount > 0 {
            let fraction = Double(keptCount) / Double(sourceCount)
            keepFraction = keepFraction.map { $0 * (1 - alpha) + fraction * alpha } ?? fraction
        }

        return TasteProfile(
            sampleCount: existing.sampleCount + picks.count + rejects.count,
            pickCount: existing.pickCount + picks.count,
            rejectCount: existing.rejectCount + rejects.count,
            sharpnessBias: blend(existing.sharpnessBias, sharpSignal),
            faceQualityBias: blend(existing.faceQualityBias, faceSignal),
            eyeOpenBias: blend(existing.eyeOpenBias, eyeSignal),
            exposureBias: blend(existing.exposureBias, expSignal),
            diversityBias: blend(existing.diversityBias, diversitySignal),
            preferredKeepFraction: keepFraction,
            updatedAt: Date()
        )
    }
}
