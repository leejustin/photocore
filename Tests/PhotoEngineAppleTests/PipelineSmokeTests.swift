import Foundation
import PhotoEngineApple
import PhotoEngineCore
import Testing

@Suite("Pipeline on synthetic photos")
struct PipelineSmokeTests {
    @Test("full pipeline culls and exports on this platform")
    func fullPipeline() throws {
        let folder = try SyntheticPhotos.makeFolder(count: 12, duplicateEvery: 4)
        defer { try? FileManager.default.removeItem(at: folder) }
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("photocore-out-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: output) }

        var profile = ScoringProfile.default(for: .trip)
        profile.sizingMode = .count
        profile.targetCount = 6
        let result = try PhotoPipelineRunner().run(
            folder: folder,
            outputDirectory: output,
            profile: profile,
            exportSpecification: ExportSpecification(preset: .compact)
        )
        #expect(result.analyzed.count == 12)
        #expect(!result.shortlist.selectedIDs.isEmpty)
        #expect(result.shortlist.selectedIDs.count <= 6)
        #expect(!result.exports.isEmpty)
        #expect(result.exports.allSatisfy { FileManager.default.fileExists(atPath: $0.outputPath) })
    }
}
