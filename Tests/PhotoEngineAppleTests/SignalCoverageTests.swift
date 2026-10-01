import Foundation
import PhotoEngineApple
import PhotoEngineCore
import Testing

@Suite("Signal coverage")
struct SignalCoverageTests {
    @Test("Vision signals are real on this platform")
    func signalsPresent() throws {
        let folder = try SyntheticPhotos.makeFolder(count: 3)
        defer { try? FileManager.default.removeItem(at: folder) }
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("sig-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: output) }
        let result = try PhotoPipelineRunner().run(folder: folder, outputDirectory: output, profile: .default(for: .trip), exportSpecification: ExportSpecification(preset: .compact))
        #expect(result.analyzed.allSatisfy { $0.signals.featurePrint != nil }, "feature prints missing")
        // Aesthetics is either absent (simulator) or varies between different images.
        let scores = result.analyzed.compactMap(\.signals.aestheticScore)
        #expect(scores.isEmpty || Set(scores).count > 1, "aesthetics returned one constant score: \(scores)")
    }
}
