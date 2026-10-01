import Foundation
import PhotoEngineApple
import PhotoEngineCore
import Testing

@Suite("Analysis cache")
struct CacheRoundTripTests {
    @Test("a cached rerun decides exactly like the fresh run")
    func cachedRunMatchesFresh() throws {
        let folder = try SyntheticPhotos.makeFolder(count: 14, duplicateEvery: 3)
        defer { try? FileManager.default.removeItem(at: folder) }
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("rt-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: output) }
        var profile = ScoringProfile.default(for: .trip)
        profile.sizingMode = .percentage
        profile.keepPercentage = 30
        let runner = PhotoPipelineRunner()
        let fresh = try runner.run(folder: folder, outputDirectory: output, profile: profile, exportSpecification: ExportSpecification(preset: .compact))
        let cached = try runner.run(folder: folder, outputDirectory: output, profile: profile, exportSpecification: ExportSpecification(preset: .compact))
        #expect(cached.metrics.cacheHits == 14)

        let freshByPath = Dictionary(uniqueKeysWithValues: fresh.analyzed.map { ($0.asset.relativePath, $0.signals) })
        for photo in cached.analyzed {
            let before = try #require(freshByPath[photo.asset.relativePath])
            #expect(before == photo.signals, "signals changed through the cache for \(photo.asset.relativePath): \(Self.diff(before, photo.signals))")
        }
        func buckets(_ result: PipelineResult) -> [String: SelectionBucket] {
            let paths = Dictionary(uniqueKeysWithValues: result.analyzed.map { ($0.id, $0.asset.relativePath) })
            return Dictionary(uniqueKeysWithValues: result.shortlist.decisions.map { (paths[$0.photoID] ?? "?", $0.bucket) })
        }
        #expect(buckets(fresh) == buckets(cached))
    }

    static func diff(_ a: AnalysisSignals, _ b: AnalysisSignals) -> String {
        Mirror(reflecting: a).children.compactMap { child -> String? in
            guard let label = child.label,
                  let other = Mirror(reflecting: b).children.first(where: { $0.label == label }) else { return nil }
            let left = String(describing: child.value), right = String(describing: other.value)
            return left == right ? nil : "\(label): \(left.prefix(80)) vs \(right.prefix(80))"
        }.joined(separator: "; ")
    }
}
