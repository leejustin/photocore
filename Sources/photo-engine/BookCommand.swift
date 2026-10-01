import Foundation
import PhotoEngineApple
import PhotoEngineCore
import PhotoEngineWorkflow

/// `photo-engine book <folder>` — cull a folder, then write the trip book:
/// finished photos, an HTML page with diary and captions, and an Instagram pack.
enum BookCommand {
    static func run(arguments: [String]) async throws {
        guard let folderPath = arguments.first else { throw PhotoEngineError.invalidArgument("book requires a folder path") }
        let folder = URL(fileURLWithPath: folderPath, isDirectory: true).standardizedFileURL
        let output = URL(fileURLWithPath: option(arguments, "--output") ?? "./exports/\(folder.lastPathComponent)-book", isDirectory: true).standardizedFileURL
        let tone = DiaryTone(rawValue: option(arguments, "--tone") ?? "warm") ?? .warm
        let theme = BookTheme(name: option(arguments, "--theme") ?? "book") ?? .book
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

        var profile = ScoringProfile.default(for: .trip)
        profile.sizingMode = .percentage
        profile.keepPercentage = Double(option(arguments, "--keep-percent") ?? "") ?? 20
        print("Culling \(folder.path)")
        let result = try PhotoPipelineRunner().run(
            folder: folder,
            outputDirectory: output.appendingPathComponent("cull", isDirectory: true),
            profile: profile,
            exportSpecification: ExportSpecification(preset: .compact)
        )
        let keepers = KeeperSelection(result: result).ordered(in: result)
        print("Kept \(keepers.count) of \(result.analyzed.count). Reading scenes and places")
        let facts = await TripFactsBuilder.build(keepers: keepers, lookUpPlaces: !arguments.contains("--offline"))
        try facts.save(to: output)

        let writer: any DiaryWriter = arguments.contains("--offline") ? TemplateDiaryWriter() : DiaryWriters.make()
        let byID = Dictionary(uniqueKeysWithValues: keepers.map { ($0.id, $0.asset.url) })
        print("Reading signs and nearby landmarks")
        let enrichment = await TripEnricher.enrich(facts: facts, source: { byID[$0.id] }, lookUpNearby: !arguments.contains("--offline"))
        let context = TripContext(note: option(arguments, "--note"))
        print("Writing the diary with \(writer.name)")
        let book = await TripBookComposer.compose(
            facts: facts,
            writer: writer,
            enrichment: enrichment,
            context: context,
            thumbnail: { byID[$0.id].flatMap { TripBookComposer.thumbnailData(url: $0) } },
            tone: tone,
            theme: theme
        )
        let report = try BookPublisher.publish(book: book, facts: facts, source: { byID[$0.id] }, to: output)
        print("Book: \(report.indexURL.path)")
        print("\(report.photoCount) finished photos, \(book.sections.count) chapters, written by \(book.writer), \(book.groundingRejections ?? 0) unsupported lines replaced")
        print("Instagram: \(report.carouselCount) carousel, \(report.storyCount) stories in \(output.appendingPathComponent("instagram").path)")
    }

    private static func option(_ arguments: [String], _ name: String) -> String? {
        guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }
}
