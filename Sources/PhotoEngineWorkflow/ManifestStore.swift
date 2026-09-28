import Foundation
import PhotoEngineApple
import PhotoEngineCore

public enum ManifestStore {
    public static func update(_ url: URL, shortlist: Shortlist, exports: [ExportedPhoto]? = nil) throws {
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let manifest = try decoder.decode(PipelineManifest.self, from: data)
        let updated = PipelineManifest(
            sessionID: manifest.sessionID,
            schemaVersion: manifest.schemaVersion,
            pipelineVersion: manifest.pipelineVersion,
            createdAt: manifest.createdAt,
            sourceFolder: manifest.sourceFolder,
            mode: manifest.mode,
            profile: manifest.profile,
            aggressiveness: manifest.aggressiveness,
            style: manifest.style,
            styleIntensity: manifest.styleIntensity,
            targetCount: manifest.targetCount,
            exportSpecification: manifest.exportSpecification,
            assets: manifest.assets,
            analyzed: manifest.analyzed,
            grouping: manifest.grouping,
            shortlist: shortlist,
            exports: exports ?? manifest.exports,
            warnings: manifest.warnings,
            metrics: manifest.metrics
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(updated).write(to: url, options: .atomic)
    }

    public static func loadResult(manifestURL: URL) throws -> PipelineResult {
        let data = try Data(contentsOf: manifestURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let manifest = try decoder.decode(PipelineManifest.self, from: data)
        let ranked = PhotoFocusRanking.apply(to: manifest.analyzed)
        let scored = ranked.map { photo in
            ScoredPhoto(photo: photo, score: PhotoScoring.score(photo, profile: manifest.profile))
        }
        return PipelineResult(
            sessionID: manifest.sessionID,
            imported: manifest.assets,
            analyzed: ranked,
            grouping: manifest.grouping,
            scored: scored,
            shortlist: manifest.shortlist,
            exports: manifest.exports,
            manifestURL: manifestURL,
            warnings: manifest.warnings.map(importIssue),
            runDirectory: manifestURL.deletingLastPathComponent(),
            storageSummary: nil,
            metrics: manifest.metrics,
            exportSpecification: manifest.exportSpecification
        )
    }

    private static func importIssue(_ warning: String) -> ImportIssue {
        if let range = warning.range(of: ": ") {
            return ImportIssue(path: String(warning[..<range.lowerBound]), message: String(warning[range.upperBound...]))
        }
        return ImportIssue(path: "", message: warning)
    }
}
