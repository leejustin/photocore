import Foundation
import PhotoEngineApple
import PhotoEngineCore

/// The paid finish, end to end: the owner's keepers (already culled on the
/// phone) plus a cull of whatever guests added, then facts, the diary, finished
/// photos, the book page and the Instagram pack.
public enum TripFinisher {
    public struct Folders: Sendable {
        public var owner: URL
        public var guests: URL
        public var book: URL
        public var work: URL

        public init(owner: URL, guests: URL, book: URL, work: URL) {
            self.owner = owner
            self.guests = guests
            self.book = book
            self.work = work
        }
    }

    public struct Outcome: Sendable {
        public var book: TripBook
        public var report: BookPublisher.Report
        public var ownerCount: Int
        public var guestKept: Int
        public var guestDuplicates: Int
    }

    /// Visual distance under which a guest frame counts as the same shot as one
    /// of the owner's (revision-2 feature prints; see the README calibration).
    public static let duplicateDistance = 0.35

    public static func finish(
        folders: Folders,
        title: String?,
        tone: DiaryTone,
        theme: BookTheme,
        writer: any DiaryWriter,
        options: BookRenderer.Options,
        lookUpPlaces: Bool = true,
        guestKeepPercent: Double = 30,
        progress: @escaping @Sendable (String, Int, Int) -> Void = { _, _, _ in }
    ) async throws -> Outcome {
        let fm = FileManager.default
        try fm.createDirectory(at: folders.work, withIntermediateDirectories: true)
        let runner = PhotoPipelineRunner()

        progress("Reading your photos", 0, 1)
        var everything = ScoringProfile.default(for: .trip)
        everything.sizingMode = .percentage
        everything.keepPercentage = 90
        let owner = try runner.run(folder: folders.owner, outputDirectory: folders.work.appendingPathComponent("owner", isDirectory: true), profile: everything, exportSpecification: ExportSpecification(preset: .compact))
        var keepers = owner.analyzed

        var guestKept = 0, guestDuplicates = 0
        let guestFiles = (try? fm.contentsOfDirectory(atPath: folders.guests.path)) ?? []
        if !guestFiles.isEmpty {
            progress("Picking the best guest photos", 0, 1)
            var guestProfile = ScoringProfile.default(for: .trip)
            guestProfile.sizingMode = .percentage
            guestProfile.keepPercentage = guestKeepPercent
            let guests = try runner.run(folder: folders.guests, outputDirectory: folders.work.appendingPathComponent("guests", isDirectory: true), profile: guestProfile, exportSpecification: ExportSpecification(preset: .compact))
            let picked = KeeperSelection(result: guests).ordered(in: guests)
            let distance = AppleVisualDistance.cachedProvider()
            for photo in picked {
                let duplicate = owner.analyzed.contains { (distance(photo.signals, $0.signals) ?? 1) < duplicateDistance }
                if duplicate { guestDuplicates += 1 } else { keepers.append(photo); guestKept += 1 }
            }
        }

        progress("Reading scenes and places", 0, keepers.count)
        let facts = await TripFactsBuilder.build(keepers: keepers, lookUpPlaces: lookUpPlaces) { done, total in
            progress("Reading scenes and places", done, total)
        }
        try facts.save(to: folders.book)
        let sources = Dictionary(keepers.map { ($0.id, $0.asset.url) }, uniquingKeysWith: { a, _ in a })

        progress("Writing the diary", 0, 1)
        var book = await TripBookComposer.compose(
            facts: facts,
            writer: writer,
            thumbnail: { sources[$0.id].flatMap { TripBookComposer.thumbnailData(url: $0) } },
            tone: tone,
            theme: theme
        )
        if let title, !title.isEmpty { book.title = title }

        progress("Finishing photos", 0, keepers.count)
        let edits = BookEdits.load(from: folders.book)
        let report = try BookPublisher.publish(book: book, edits: edits, facts: facts, source: { sources[$0.id] }, to: folders.book, options: options)
        return Outcome(book: book, report: report, ownerCount: owner.analyzed.count, guestKept: guestKept, guestDuplicates: guestDuplicates)
    }

    /// Applies one owner edit and re-renders the page without touching photos.
    public static func applyEdit(key: String, value: String, bookFolder: URL, options: BookRenderer.Options) throws {
        guard BookEdits.isAllowed(key: key) else { throw EditError.notEditable }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count <= BookEdits.maximumLength else { throw EditError.tooLong }
        let book = try TripBook.load(from: bookFolder)
        var edits = BookEdits.load(from: bookFolder)
        edits.values[key] = trimmed
        try edits.save(to: bookFolder)
        try Data(BookRenderer.html(edits.applied(to: book), options: options).utf8)
            .write(to: bookFolder.appendingPathComponent("index.html"), options: .atomic)
    }

    public enum EditError: Error, Equatable {
        case notEditable
        case tooLong
    }
}
