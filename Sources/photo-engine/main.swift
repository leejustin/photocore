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
        let mode = CurationMode(rawValue: option(arguments, name: "--profile") ?? "everyday") ?? .everyday
        let targetCount = Int(option(arguments, name: "--target") ?? "")
        var profile = ScoringProfile.default(for: mode)
        if let targetCount, targetCount > 0 { profile.targetCount = targetCount }

        let outputPath = option(arguments, name: "--output") ?? "./exports/\(folder.lastPathComponent)-curated"
        let output = URL(fileURLWithPath: outputPath, isDirectory: true).standardizedFileURL
        let runner = PhotoPipelineRunner()
        let result = try runner.run(folder: folder, outputDirectory: output, profile: profile) { progress in
            let suffix = progress.total > 0 ? " (\(progress.completed)/\(progress.total))" : ""
            print("[\(progress.stage.rawValue)] \(progress.message)\(suffix)")
        }
        print("\nSelected \(result.shortlist.selectedIDs.count) of \(result.imported.count) photos")
        print("Exported to \(result.runDirectory.appendingPathComponent("shortlist").path)")
        print("Manifest: \(result.manifestURL.path)")
        if !result.warnings.isEmpty {
            print("Warnings: \(result.warnings.count) supported file(s) could not be imported")
            for warning in result.warnings.prefix(10) {
                print("- \(warning.path): \(warning.message)")
            }
        }
    }

    private static func option(_ arguments: [String], name: String) -> String? {
        guard let index = arguments.firstIndex(of: name), arguments.indices.contains(index + 1) else { return nil }
        return arguments[index + 1]
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
          photo-engine run <folder> [--profile everyday|groupEvent|trip|creative] [--target N] [--output folder]
          photo-engine smoke-test
          photo-engine version
        """)
    }
}
