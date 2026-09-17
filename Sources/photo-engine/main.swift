import Foundation
import PhotoEngineApple
import PhotoEngineCore

@main
struct PhotoEngineCommand {
    static func main() {
        do {
            try run(arguments: Array(CommandLine.arguments.dropFirst()))
        } catch {
            fputs("error: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

    private static func run(arguments: [String]) throws {
        guard let command = arguments.first else {
            printUsage()
            return
        }

        switch command {
        case "version":
            print("photo-engine 0.2.0")
        case "catalog":
            guard arguments.count >= 2 else { throw PhotoEngineError.invalidArgument("catalog requires a folder path") }
            let folder = URL(fileURLWithPath: arguments[1], isDirectory: true).standardizedFileURL
            let imported = try PhotoFolderImporter().importFolder(folder)
            print("Found \(imported.count) supported photos")
            for photo in imported.prefix(20) {
                print("- \(photo.asset.relativePath) (\(photo.asset.metadata.pixelWidth)x\(photo.asset.metadata.pixelHeight))")
            }
            if imported.count > 20 { print("… and \(imported.count - 20) more") }
        case "run":
            try runPipeline(arguments: Array(arguments.dropFirst()))
        case "smoke-test":
            try runSmokeTests()
        case "help", "--help", "-h":
            printUsage()
        default:
            throw PhotoEngineError.invalidArgument("Unknown command '\(command)'. Use 'photo-engine help'.")
        }
    }

    private static func runPipeline(arguments: [String]) throws {
        guard let folderPath = arguments.first else { throw PhotoEngineError.invalidArgument("run requires a folder path") }
        let folder = URL(fileURLWithPath: folderPath, isDirectory: true).standardizedFileURL
        let rawMode = option(arguments, name: "--profile") ?? "everyday"
        guard let mode = CurationMode(rawValue: rawMode) else {
            throw PhotoEngineError.invalidArgument("Unknown profile '\(rawMode)'.")
        }
        let rawTarget = option(arguments, name: "--target")
        let targetCount = rawTarget.flatMap(Int.init)
        if rawTarget != nil && (targetCount ?? 0) <= 0 {
            throw PhotoEngineError.invalidArgument("Target must be a positive integer.")
        }
        var profile = ScoringProfile.default(for: mode)
        if let targetCount, targetCount > 0 { profile.targetCount = targetCount }
        if let rawAggressiveness = option(arguments, name: "--cull") {
            guard let aggressiveness = CullingAggressiveness(rawValue: rawAggressiveness) else {
                throw PhotoEngineError.invalidArgument("Unknown culling preset '\(rawAggressiveness)'. Use gentle, balanced, or highlights.")
            }
            profile.apply(aggressiveness: aggressiveness)
        }
        if let rawStyle = option(arguments, name: "--style") {
            guard let style = StylePreset(rawValue: rawStyle) else {
                throw PhotoEngineError.invalidArgument("Unknown style '\(rawStyle)'. Use natural, warm, vibrant, soft, or blackAndWhite.")
            }
            profile.style = style
        }
        if let rawIntensity = option(arguments, name: "--intensity") {
            guard let intensity = Double(rawIntensity), intensity.isFinite, (0...1).contains(intensity) else {
                throw PhotoEngineError.invalidArgument("Style intensity must be a number between 0 and 1.")
            }
            profile.styleIntensity = intensity
        }
        let exportPreset: ExportPreset
        if let rawSize = option(arguments, name: "--size") {
            guard let parsed = ExportPreset(rawValue: rawSize) else {
                throw PhotoEngineError.invalidArgument("Unknown export size '\(rawSize)'. Use full or compact.")
            }
            exportPreset = parsed
        } else {
            exportPreset = .full
        }

        let outputPath = option(arguments, name: "--output") ?? "./exports/\(folder.lastPathComponent)-curated"
        let output = URL(fileURLWithPath: outputPath, isDirectory: true).standardizedFileURL
        let runner = PhotoPipelineRunner()
        let result = try runner.run(
            folder: folder,
            outputDirectory: output,
            profile: profile,
            exportSpecification: ExportSpecification(preset: exportPreset)
        ) { progress in
            let suffix = progress.total > 0 ? " (\(progress.completed)/\(progress.total))" : ""
            print("[\(progress.stage.rawValue)] \(progress.message)\(suffix)")
        }
        print("\nSelected \(result.shortlist.selectedIDs.count) of \(result.imported.count) photos")
        print("Session: \(result.sessionID)")
        print("Exported to \(result.runDirectory.appendingPathComponent("shortlist").path)")
        print("Manifest: \(result.manifestURL.path)")
        print(String(format: "Timing: %.2fs total, %.2fs analysis, %d cache hits, %d exact-content reuses", result.metrics.totalSeconds, result.metrics.analysisSeconds, result.metrics.cacheHits, result.metrics.exactContentReuses))
        if let summary = result.storageSummary {
            print("Storage: \(formatBytes(summary.sourceBytes)) source + \(formatBytes(summary.generatedBytes)) generated + \(formatBytes(summary.cacheBytes)) cache")
        }
        if !result.warnings.isEmpty {
            print("Warnings: \(result.warnings.count)")
            for warning in result.warnings.prefix(10) {
                print("- \(warning.path): \(warning.message)")
            }
        }
    }

    private static func option(_ arguments: [String], name: String) -> String? {
        guard let index = arguments.firstIndex(of: name), arguments.indices.contains(index + 1) else { return nil }
        return arguments[index + 1]
    }

    private static func formatBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private static func runSmokeTests() throws {
        for mode in CurationMode.allCases {
            let profile = ScoringProfile.default(for: mode)
            precondition(profile.targetCount > 0, "profile target must be positive")
            precondition(profile.burstWindow > 0, "profile burst window must be positive")
        }

        precondition(PhotoSimilarity.hammingDistance(0, 0) == 0, "zero hamming distance failed")
        precondition(PhotoSimilarity.hammingDistance(UInt64.max, 0) == 64, "max hamming distance failed")
        precondition(PhotoFolderImporter.isSupportedImage(URL(fileURLWithPath: "/tmp/photo.JPG")), "JPEG extension check failed")
        precondition(PhotoFolderImporter.isSupportedImage(URL(fileURLWithPath: "/tmp/photo.heic")), "HEIC extension check failed")
        precondition(!PhotoFolderImporter.isSupportedImage(URL(fileURLWithPath: "/tmp/photo.png")), "PNG should not be in the initial input contract")

        let photos = (0..<5).map { index in
            let asset = PhotoAsset(
                url: URL(fileURLWithPath: "/tmp/photo-\(index).jpg"),
                relativePath: "photo-\(index).jpg",
                metadata: PhotoMetadata(pixelWidth: 100, pixelHeight: 100)
            )
            let analyzed = AnalyzedPhoto(
                asset: asset,
                signals: AnalysisSignals(
                    fingerprint: PhotoFingerprint(contentHash: "hash-\(index)", perceptualHash: UInt64(index)),
                    brightness: 0.5,
                    exposureQuality: 0.8,
                    sharpness: 0.8,
                    faceQuality: 0.5,
                    faceCount: 0,
                    aestheticScore: 0.8,
                    aestheticUtility: false,
                    featurePrint: nil,
                    faces: []
                )
            )
            return ScoredPhoto(photo: analyzed, score: PhotoScoring.score(analyzed, profile: .default(for: .everyday)))
        }
        var profile = ScoringProfile.default(for: .everyday)
        profile.targetCount = 2
        let shortlist = PhotoSelectionEngine.select(photos, grouping: PhotoGrouping(groups: []), profile: profile)
        precondition(shortlist.selectedIDs.count == 2, "selection target failed")
        print("Smoke tests passed")
    }

    private static func printUsage() {
        print("""
        photo-engine 0.2.0

        Usage:
          photo-engine catalog <folder>
          photo-engine run <folder> [--profile everyday|groupEvent|trip|creative] [--cull gentle|balanced|highlights] [--target N] [--style natural|warm|vibrant|soft|blackAndWhite] [--intensity 0...1] [--size full|compact] [--output folder]
          photo-engine smoke-test
          photo-engine version
        """)
    }
}
